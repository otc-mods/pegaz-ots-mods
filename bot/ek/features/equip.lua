-- Equip tab: slot rules with conditions, executed with g_game.equipItemId (works with a closed backpack).
setDefaultTab("Tools")

local equipTabPanel = panel
panel = UI.section("toolsEquip", "Equip", equipTabPanel)

local SLOT_NAMES = {"Head", "Neck", "Back", "Body", "Right", "Left", "Legs", "Feet", "Ring", "Ammo", "Purse"}
-- a condition = on-zone test + optional off threshold (hysteresis) with its own zone. A rule has one or two
-- conditions: it equips while ALL are on, takes the item off when ANY crossed its off threshold, else leaves it.
local function hp() return player:getHealthPercent() end
local function mobs() return Hunt.monstersNear(3) end
local function plrs() return Hunt.playersNear(7) end
local CONDS = {
  { id = "always",        text = "always",               min = 0, max = 0 },
  { id = "hpBelow",       text = "HP% below",            min = 1, max = 100, offBeyond = "above",
    on = function(v) return hp() < v end,          off = function(o) return hp() > o end,
    label = function(v) return "HP < " .. v .. "%" end,    offLabel = function(o) return "HP > " .. o .. "%" end,
    short = function(v) return "HP<" .. v end },
  { id = "hpAbove",       text = "HP% above",            min = 1, max = 100, offBeyond = "below",
    on = function(v) return hp() > v end,          off = function(o) return hp() < o end,
    label = function(v) return "HP > " .. v .. "%" end,    offLabel = function(o) return "HP < " .. o .. "%" end,
    short = function(v) return "HP>" .. v end },
  { id = "manaBelow",     text = "Mana% below",          min = 1, max = 100, offBeyond = "above",
    on = function(v) return manapercent() < v end, off = function(o) return manapercent() > o end,
    label = function(v) return "MP < " .. v .. "%" end,    offLabel = function(o) return "MP > " .. o .. "%" end,
    short = function(v) return "MP<" .. v end },
  { id = "manaAbove",     text = "Mana% above",          min = 1, max = 100, offBeyond = "below",
    on = function(v) return manapercent() > v end, off = function(o) return manapercent() < o end,
    label = function(v) return "MP > " .. v .. "%" end,    offLabel = function(o) return "MP < " .. o .. "%" end,
    short = function(v) return "MP>" .. v end },
  { id = "monsters",      text = "monsters (3 sqm) >=",  min = 1, max = 10,  offBeyond = "below",
    on = function(v) return mobs() >= v end,       off = function(o) return mobs() < o end,
    label = function(v) return "mobs >= " .. v end,        offLabel = function(o) return "mobs < " .. o end,
    short = function(v) return "mobs>=" .. v end },
  { id = "monstersBelow", text = "monsters (3 sqm) <",   min = 1, max = 10,  offBeyond = "above",
    on = function(v) return mobs() < v end,        off = function(o) return mobs() >= o end,
    label = function(v) return "mobs < " .. v end,         offLabel = function(o) return "mobs >= " .. o end,
    short = function(v) return "mobs<" .. v end },
  { id = "players",       text = "players on screen >=", min = 1, max = 10,  offBeyond = "below",
    on = function(v) return plrs() >= v end,       off = function(o) return plrs() < o end,
    label = function(v) return "players >= " .. v end,     offLabel = function(o) return "players < " .. o end,
    short = function(v) return "plr>=" .. v end },
  { id = "playersBelow",  text = "players on screen <",  min = 1, max = 10,  offBeyond = "above",
    on = function(v) return plrs() < v end,        off = function(o) return plrs() >= o end,
    label = function(v) return "players < " .. v end,      offLabel = function(o) return "players >= " .. o end,
    short = function(v) return "plr<" .. v end },
}
local NO_COND = { id = "none", text = "-", min = 0, max = 0 }
local MAX_RULES = 6
local RETRY_MS = 300      -- wait for the server before re-sending an equip
local PROBE_EVERY_MS = 5 * 60 * 1000 -- count-probe before an empty-slot equip, per item, at most this often
-- spam until it lands: a laggy server answers late and drops queued actions. Back off briefly only after
-- many tries (the item is probably not in any backpack), never for long.
local GIVE_UP_TRIES = 12
local BACKOFF_MS = 3000

local function condById(id)
  for _, c in ipairs(CONDS) do if c.id == id then return c end end
  return CONDS[1]
end

-- rings (and some amulets) change id when worn: backpack id -> worn id, learned automatically
if type(storage.equipWornIds) ~= "table" then storage.equipWornIds = {} end
local function wornOf(item) return storage.equipWornIds[tostring(item)] end
local function wornIdFor(r) return (r.worn and r.worn > 100) and r.worn or wornOf(r.item) end

-- one-time migration from the stock "Auto equip" panels (item1 = in backpack, item2 = same item worn)
if type(storage.equipRules) ~= "table" then
  storage.equipRules = {}
  for _, ae in ipairs(storage.autoEquip or {}) do
    if ae.item1 and ae.item1 > 100 and ae.slot and ae.slot > 0 then
      table.insert(storage.equipRules, {on = ae.on and true or false, slot = ae.slot, item = ae.item1, cond = "always", value = 0})
      if ae.item2 and ae.item2 > 100 and ae.item2 ~= ae.item1 then storage.equipWornIds[tostring(ae.item1)] = ae.item2 end
    end
  end
end
local rules = storage.equipRules
-- one-time repair (2026-09-07): Pegaz elven amulet is 2854 in the backpack and 3082 worn; a rule on 3082 can never equip
if storage.equipAmuletRepair ~= 2 then -- undo the wrong 2854 repair: the amulet is 3082 in the bag as well
  for _, r in ipairs(rules) do
    if r.item == 2854 then r.item = 3082 end
    if r.item == 3082 and r.worn == 3082 then r.worn = nil end
  end
  storage.equipWornIds["2854"] = nil
  storage.equipAmuletRepair = 2
end
for _, r in ipairs(rules) do
  if not (r.worn and r.worn > 100) and wornOf(r.item) then r.worn = wornOf(r.item) end
end

-- condition n (1 or 2) of a rule: definition, value, off threshold; nil when absent
local function part(r, n)
  if n == 1 then return condById(r.cond), r.value or 0, r.off or 0 end
  if r.cond2 and r.cond2 ~= "none" then return condById(r.cond2), r.value2 or 0, r.off2 or 0 end
  return nil
end

local function hasOff(r)
  for n = 1, 2 do
    local c, _, o = part(r, n)
    if c and c.off and o > 0 then return true end
  end
  return false
end

local function condTrue(r)
  for n = 1, 2 do
    local c, v = part(r, n)
    if c and c.on and not c.on(v) then return false end
  end
  return true
end

local function offTrue(r)
  for n = 1, 2 do
    local c, _, o = part(r, n)
    if c and c.off and o > 0 and c.off(o) then return true end
  end
  return false
end

local function ruleLongText(r)
  local parts = {}
  for n = 1, 2 do
    local c, v, o = part(r, n)
    if c then
      local t = c.label and c.label(v) or "always"
      if c.off and o > 0 then t = t .. ", off when " .. c.offLabel(o) end
      table.insert(parts, t)
    end
  end
  return (SLOT_NAMES[r.slot] or "?") .. ": " .. table.concat(parts, " and ")
end

-- the row button holds about 20 characters: "HP<50/80" = on below 50, off above 80; full sentence in the tooltip
local function ruleText(r)
  local parts = {}
  for n = 1, 2 do
    local c, v, o = part(r, n)
    if c then
      local t = c.short and c.short(v) or "always"
      if c.off and o > 0 then t = t .. "/" .. o end
      table.insert(parts, t)
    end
  end
  -- 122px of button: "Ring HP<50/80+MP>49/10" fits, "Ring: HP<50/80 & MP>49/10" does not
  return (SLOT_NAMES[r.slot] or "?") .. " " .. table.concat(parts, "+")
end

-- engine ----------------------------------------------------------------------------
local pending = {} -- slot -> {item, due, tries}
local lastProbe = {} -- item -> time of the last count probe
local blocked = {} -- item -> until
local pendingOff = {} -- slot -> {due, tries}
local offBlocked = {} -- slot -> until
local status

local function takeOff(slot, cur, item)
  local p = pendingOff[slot]
  if p and p.due > now then return end -- sent, waiting for the server
  if offBlocked[slot] and offBlocked[slot] > now then return end
  local tries = p and p.tries + 1 or 1
  if tries > GIVE_UP_TRIES then
    offBlocked[slot] = now + BACKOFF_MS
    pendingOff[slot] = nil
    status:setText("cannot take off " .. (SLOT_NAMES[slot] or slot) .. " (backpack full?), retry in " .. (BACKOFF_MS / 1000) .. "s")
    return
  end
  status:setText("taking off " .. (SLOT_NAMES[slot] or slot) .. " (" .. tries .. ")")
  -- the equip hotkey packet toggles: asking to equip the id that is already worn makes the server take it off
  -- (moving the item onto the backpack slot was ignored by Pegaz)
  g_game.equipItemId(cur:getId())
  pendingOff[slot] = {due = now + RETRY_MS, tries = tries, item = item}
end

-- stateless, every tick: condition true -> the slot must hold the item (spam equip); off-condition true -> the
-- slot must not hold it (spam take-off); in between -> leave the slot alone. Rule order = priority per slot.
-- does another rule use this id (bag or worn)? Then it is not ours to take off when our worn id is unknown
local function claimedByOther(rule, id)
  for _, o in ipairs(rules) do
    if o ~= rule and (o.item == id or wornIdFor(o) == id) then return true end
  end
  return false
end

local equipMacro = macro(100, "Equip", function()
  local wanted, release = {}, {} -- slot -> item ; rules whose off-condition holds
  for _, r in ipairs(rules) do
    if r.on and r.item > 100 then
      if condTrue(r) then
        if not wanted[r.slot] and not (blocked[r.item] and blocked[r.item] > now) then wanted[r.slot] = r.item end
      elseif hasOff(r) and offTrue(r) then
        table.insert(release, r)
      end
    end
  end
  -- each rule takes off only its own item (bag or worn id). Worn id not learned yet: whatever sits there,
  -- unless another rule claims that id (the energy ring rule must never strip the might ring).
  local takingOff = {}
  for _, r in ipairs(release) do
    local slot = r.slot
    if not wanted[slot] and not takingOff[slot] then
      local cur = getInventoryItem(slot)
      local curId = cur and cur:getId() or 0
      local worn = wornIdFor(r)
      local mine = curId ~= 0 and (curId == r.item or curId == worn or (not worn and not claimedByOther(r, curId)))
      local p = pendingOff[slot]
      if mine then
        takingOff[slot] = true
        takeOff(slot, cur, r.item)
      elseif p and p.item == r.item then
        Hunt.fireUnequipped(r.item) -- our take-off landed: the spare is back in the bag
        pendingOff[slot] = nil
      end
    end
  end
  for slot, p in pairs(pendingOff) do
    if not takingOff[slot] then
      local cur = getInventoryItem(slot)
      local curId = cur and cur:getId() or 0
      if p.item and curId ~= p.item and curId ~= wornOf(p.item) then Hunt.fireUnequipped(p.item) end
      pendingOff[slot] = nil
    end
  end
  for slot, item in pairs(wanted) do
    local cur = getInventoryItem(slot)
    local curId = cur and cur:getId() or 0
    local p = pending[slot]
    if p and p.item == item and curId ~= 0 and curId ~= item and curId ~= p.prevId and not wornOf(item) then
      storage.equipWornIds[tostring(item)] = curId -- our equip landed and the item shows up under another id
      for _, r in ipairs(rules) do if r.item == item and not (r.worn and r.worn > 100) then r.worn = curId end end
    end
    local wornId = wornOf(item)
    for _, r in ipairs(rules) do if r.item == item and r.worn and r.worn > 100 then wornId = r.worn end end
    if curId == item or curId == wornId then
      if p and p.item == item then Hunt.fireEquipped(item) end -- our equip landed
      pending[slot] = nil
      blocked[item] = nil
    elseif p and p.item == item and p.due > now then
      -- sent, waiting for the server
    else
      local tries = (p and p.item == item) and p.tries + 1 or 1
      if tries > GIVE_UP_TRIES then
        blocked[item] = now + BACKOFF_MS
        pending[slot] = nil
        status:setText("no item " .. item .. " for " .. (SLOT_NAMES[slot] or slot) .. ", retry in " .. (BACKOFF_MS / 1000) .. "s")
      else
        -- count probe only in calm moments: it is an extra server action queued in front of the equip
        if curId == 0 and Hunt.equipProbeWanted(item) and (lastProbe[item] or 0) + PROBE_EVERY_MS <= now and Hunt.monstersNear(3) == 0 then
          lastProbe[item] = now
          Hunt.fireEquipProbe(item)     -- icons mark the reply as a probe answer
          g_game.useInventoryItem(item) -- slot empty: the server finds a fresh spare and prints "Using one of N"
        end
        g_game.equipItemId(item)
        pending[slot] = {item = item, due = now + RETRY_MS, tries = tries, prevId = curId}
        Hunt.setEquipPending(now + RETRY_MS)
        status:setText("")
        return -- one equip per tick
      end
    end
  end
end)
Features.register{ id = "equip", name = "Equip", group = "Other", macro = equipMacro }

-- ui ----------------------------------------------------------------------------------
UI.Label("Equip rules (top rule wins)")
local list = UI.createWidget('EquipRuleList')
local addButton
status = UI.createWidget('BotLabel') -- UI.Label() returns nothing
status:setText("")

local rebuild
local function editRule(r, isNew)
  local w = UI.createWindow('EquipRuleEditor')
  local draft = {slot = r.slot or 9, item = r.item or 0, worn = r.worn or wornOf(r.item or 0) or 0,
                 cond = r.cond or "always", value = r.value or 0, off = r.off or 0,
                 cond2 = r.cond2 or "none", value2 = r.value2 or 0, off2 = r.off2 or 0}

  local slotRow = UI.createWidget('EquipRuleEditorSlotRow', w.content)
  local slotBox = slotRow.slot
  slotBox:setCurrentIndex(draft.slot)
  slotBox.onOptionChange = function() draft.slot = slotBox.currentIndex end

  local itemRow = UI.createWidget('EquipRuleEditorItemRow', w.content)
  itemRow.text:setText("Item (bag)")
  local itemBox = itemRow.item
  itemBox:setItemId(draft.item)
  itemBox.onItemChange = function() draft.item = itemBox:getItemId() end

  local wornRow = UI.createWidget('EquipRuleEditorItemRow', w.content)
  wornRow.text:setText("Worn as")
  wornRow.text:setTooltip("Optional: the id the item gets when equipped (rings, some amulets change id). Learned automatically after a successful equip.")
  local wornBox = wornRow.item
  wornBox:setItemId(draft.worn)
  wornBox.onItemChange = function() draft.worn = wornBox:getItemId() end

  -- one block per condition: type combo + value slider + off slider (the latter two only when the type has a value)
  local blocks = {}
  local relayout
  local function condBlock(n, labelText, options, condKey, valueKey, offKey)
    local blk = {}
    local condRow = UI.createWidget('EquipRuleEditorCondRow', w.content)
    condRow.text:setText(labelText)
    local combo = condRow.cond
    for i, c in ipairs(options) do
      combo:addOption(c.text, c.id)
      if c.id == draft[condKey] then combo:setCurrentIndex(i) end
    end
    local valueRow = UI.createWidget('EquipRuleEditorValueRow', w.content)
    local offRow = UI.createWidget('EquipRuleEditorValueRow', w.content)
    offRow.text:setWidth(96)
    offRow.text:setTooltip("Take the item off again when this holds. 0 = never because of this condition.")
    local function current() return draft[condKey] == "none" and NO_COND or condById(draft[condKey]) end
    local function offText()
      local c = current()
      if draft[offKey] > 0 and c.offLabel then return "Off: " .. c.offLabel(draft[offKey]) end
      return "Off: never"
    end
    function blk.apply()
      local c = current()
      if c.max == 0 then
        valueRow:hide() offRow:hide()
        blk.rows = 1
      else
        valueRow:show() offRow:show()
        blk.rows = 3
        local step = c.max > 20 and 5 or 1
        valueRow.value:setRange(c.min, c.max) valueRow.value:setStep(step)
        valueRow.value:setValue(math.max(c.min, math.min(c.max, draft[valueKey])))
        draft[valueKey] = valueRow.value:getValue()
        valueRow.text:setText("Value: " .. draft[valueKey])
        offRow.value:setRange(0, c.max) offRow.value:setStep(step)
        offRow.value:setValue(math.max(0, math.min(c.max, draft[offKey])))
        draft[offKey] = offRow.value:getValue()
        offRow.text:setText(offText())
      end
    end
    valueRow.value.onValueChange = function(_, v) draft[valueKey] = v valueRow.text:setText("Value: " .. v) end
    offRow.value.onValueChange = function(_, v) draft[offKey] = v offRow.text:setText(offText()) end
    combo.onOptionChange = function(_, _, data) draft[condKey] = data blk.apply() relayout() end
    blocks[n] = blk
    return blk
  end
  local second = { NO_COND }
  for _, c in ipairs(CONDS) do if c.id ~= "always" then table.insert(second, c) end end
  condBlock(1, "When", CONDS, "cond", "value", "off")
  condBlock(2, "And", second, "cond2", "value2", "off2")
  relayout = function()
    local rows = 0
    for _, blk in ipairs(blocks) do rows = rows + (blk.rows or 1) end
    w:setHeight(192 + rows * 29) -- slot + item + worn rows and buttons = 192, each condition row ~29 px
  end
  for _, blk in ipairs(blocks) do blk.apply() end
  relayout()

  w.cancel.onClick = function() w:destroy() end
  w.onEscape = w.cancel.onClick
  w.remove.onClick = function()
    if not isNew then
      for i, x in ipairs(rules) do if x == r then table.remove(rules, i) break end end
    end
    w:destroy()
    rebuild()
  end
  w.ok.onClick = function()
    if draft.item <= 100 then return end
    -- the off threshold must lie beyond the on threshold (or equal: no gap), else it is pulled to the value
    local function clampOff(condId, value, off)
      local c = condById(condId)
      if not c.off or off <= 0 then return nil end
      if c.offBeyond == "above" and off < value then off = value end
      if c.offBeyond == "below" and off > value then off = value end
      return off
    end
    r.slot, r.item, r.cond, r.value = draft.slot, draft.item, draft.cond, draft.value
    r.off = clampOff(draft.cond, draft.value, draft.off)
    if draft.cond2 ~= "none" then
      r.cond2, r.value2, r.off2 = draft.cond2, draft.value2, clampOff(draft.cond2, draft.value2, draft.off2)
    else
      r.cond2, r.value2, r.off2 = nil, nil, nil
    end
    r.worn = (draft.worn and draft.worn > 100 and draft.worn ~= draft.item) and draft.worn or nil
    if r.worn then storage.equipWornIds[tostring(r.item)] = r.worn end
    if isNew then
      r.on = true
      table.insert(rules, r)
    end
    w:destroy()
    rebuild()
  end
end

local rowsByRule = {} -- rule -> row, so toggles made elsewhere (icons) show up here
macro(500, function()
  for r, row in pairs(rowsByRule) do
    if not row:isDestroyed() then row.title:setOn(r.on) end
  end
end)

rebuild = function()
  list:destroyChildren()
  rowsByRule = {}
  for idx, r in ipairs(rules) do
    local row = UI.createWidget('EquipRuleRow', list)
    rowsByRule[r] = row
    row.item:setItemId(r.item)
    row.item.onItemChange = function() r.item = row.item:getItemId() end
    row.title:setText(ruleText(r))
    row.title:setTooltip(ruleLongText(r))
    row.title:setOn(r.on)
    row.title.onClick = function()
      r.on = not r.on
      row.title:setOn(r.on)
    end
    row.edit.onClick = function() editRule(r, false) end
    local i = idx
    row.up:setEnabled(i > 1)
    row.down:setEnabled(i < #rules)
    row.up.onClick = function()
      rules[i], rules[i - 1] = rules[i - 1], rules[i]
      rebuild()
    end
    row.down.onClick = function()
      rules[i], rules[i + 1] = rules[i + 1], rules[i]
      rebuild()
    end
  end
  addButton:setVisible(#rules < MAX_RULES)
end

addButton = UI.Button("Add rule", function() editRule({}, true) end)
rebuild()

panel = equipTabPanel
