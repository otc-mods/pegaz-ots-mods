-- Autoloot GUI: named loot lists drawn as 15-slot backpacks, item search over the client's pickupable
-- item types, Apply = "!autoloot clear" + "!autoloot add <name>" per item. Unlocked slot count comes from
-- the server's "Autoloot: X/Y slotow." reply. Names: items_860.lua (AutolootNames) + user-set names.

MAX_RESULTS = 1000          -- one widget per item: more than this and opening the window drags
SLOTS_PER_BAG = 15           -- server maximum
DEFAULT_UNLOCKED = 3         -- until the server tells us
CAROUSEL_SIZE = 5
SEND_INTERVAL = 1100         -- ms between chat commands (server anti-spam)
SLOTS_PATTERN = "Autoloot:%s*(%d+)%s*/%s*(%d+)"
GREY = '#555555'
RED = '#ff6666'

local window, button
local data          -- { lists = { {name=, items={id,...}} }, active = n, customNames = { [tostring(id)] = name } }
local allItems      -- sorted array of item ids (pickupable), built on first use
local slotsUsed, slotsMax
local carouselStart = 1
local serverItems = {}       -- what the server reported on the last bare !autoloot: { {id=, name=}, ... }
local collectUntil = 0       -- reply lines arriving before this time are part of the list reply
local nameIndex              -- lower-case name -> id (bundled + custom), built lazily
local resultsSummary = ""    -- the counts line, restored when the mouse leaves an item
local sendQueue, sendEvent = {}, nil
-- price book: what NPCs pay, learned from every trade window you open. prices[id] = {sell=, weight=, npc=, name=}
local prices = {}
-- the picked sort lives in data (saved with the lists), sortMode mirrors it for the sort comparators
SORT_MODES = { { id = 'name', text = 'name' }, { id = 'value', text = 'sell price' }, { id = 'density', text = 'gold per oz' } }

-- persistence -----------------------------------------------------------------------
local function save() g_settings.setNode('autoloot', data) end
local priceMeta = { npc = nil, at = nil, count = 0 } -- who taught us last and when (os.time)

local function savePrices()
  g_settings.setNode('autolootPrices', prices)
  g_settings.setNode('autolootPricesMeta', priceMeta)
end

local function loadPrices()
  prices = {}
  local node = g_settings.getNode('autolootPrices')
  if type(node) == 'table' then
    for id, p in pairs(node) do
      local n = tonumber(id)
      if n and type(p) == 'table' and tonumber(p.sell) then
        prices[n] = { sell = tonumber(p.sell), weight = tonumber(p.weight) or 0, npc = p.npc, name = p.name }
      end
    end
  end
  local meta = g_settings.getNode('autolootPricesMeta')
  if type(meta) == 'table' then
    priceMeta = { npc = meta.npc, at = tonumber(meta.at), count = tonumber(meta.count) or 0 }
  end
end

local function ago(t)
  if not t then return nil end
  local d = os.time() - t
  if d < 60 then return 'just now' end
  if d < 3600 then return math.floor(d / 60) .. ' min ago' end
  if d < 86400 then return math.floor(d / 3600) .. ' h ago' end
  return math.floor(d / 86400) .. ' days ago'
end

-- shop names are the server's own: they beat the bundled 8.60 table and fill in items it does not know
local function priceOf(id) return prices[id] end
local function sellOf(id) local p = prices[id] return p and p.sell or 0 end
local function densityOf(id)
  local p = prices[id]
  if not p or not p.sell or (p.weight or 0) <= 0 then return 0 end
  return p.sell / p.weight
end

local function fmtGold(n)
  if n >= 1000000 then return string.format('%.1fkk', n / 1000000) end
  if n >= 1000 then return string.format('%.1fk', n / 1000) end
  return tostring(n)
end

-- g_settings stores arrays as "1:", "2:" child nodes and may hand them back with string keys: rebuild real arrays
local function toArray(t)
  if type(t) ~= 'table' then return {} end
  local entries = {}
  for k, v in pairs(t) do
    local n = tonumber(k)
    if n then table.insert(entries, {n, v}) end
  end
  table.sort(entries, function(a, b) return a[1] < b[1] end)
  local out = {}
  for _, e in ipairs(entries) do table.insert(out, e[2]) end
  return out
end

local function load()
  local raw = g_settings.getNode('autoloot')
  data = { lists = {}, active = 1, customNames = {}, ownTips = true, pricedOnly = false, sort = 'name' }
  local function flag(v) return v == true or v == 'true' or v == 1 end
  if type(raw) == 'table' then
    if raw.ownTips ~= nil then data.ownTips = flag(raw.ownTips) end
    data.pricedOnly = flag(raw.pricedOnly)
    for _, m in ipairs(SORT_MODES) do if raw.sort == m.id then data.sort = m.id end end
    for _, l in ipairs(toArray(raw.lists)) do
      if type(l) == 'table' and l.name then
        local items = {}
        for _, id in ipairs(toArray(l.items)) do
          id = tonumber(id)
          if id and id > 0 then table.insert(items, id) end
        end
        table.insert(data.lists, { name = tostring(l.name), items = items })
      end
    end
    if type(raw.customNames) == 'table' then
      for k, v in pairs(raw.customNames) do data.customNames[tostring(k)] = tostring(v) end
    end
    data.active = tonumber(raw.active) or 1
  end
  if #data.lists == 0 then data.lists = { { name = "Backpack 1", items = {} } } end
  data.active = math.max(1, math.min(#data.lists, data.active))
end

local function activeList() return data.lists[data.active] end
local function unlocked() return slotsMax or DEFAULT_UNLOCKED end
local function nameOf(id)
  local p = prices[id]
  return data.customNames[tostring(id)] or (p and p.name) or AutolootNames[id]
end

local function idOf(name)
  if not nameIndex then
    nameIndex = {}
    local ids = {}
    for id in pairs(AutolootNames) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local key = AutolootNames[id]:lower()
      if not nameIndex[key] then nameIndex[key] = id end -- lowest id wins (the "in backpack" form of rings)
    end
  end
  local key = name:lower()
  for id, custom in pairs(data.customNames) do
    if custom:lower() == key then return tonumber(id) end
  end
  return nameIndex[key]
end

-- item index ------------------------------------------------------------------------
local function buildIndex()
  allItems = {}
  local ok, types = pcall(function() return g_things.getThingTypes(ThingCategoryItem) end)
  if ok and type(types) == 'table' and #types > 0 then
    for _, tt in ipairs(types) do
      local id = tt:getId()
      if id >= 100 and tt:isPickupable() then table.insert(allItems, id) end
    end
  else
    for id = 100, 20000 do
      local tt = g_things.getThingType(id, ThingCategoryItem)
      if tt and tt:getId() == id and tt:isPickupable() then table.insert(allItems, id) end
    end
  end
  table.sort(allItems, function(a, b)
    local na, nb = nameOf(a), nameOf(b)
    if na and nb then if na ~= nb then return na < nb end return a < b end
    if na then return true end
    if nb then return false end
    return a < b
  end)
end

-- our own tooltip for the item list: everything the price book knows
local function itemTooltip(id)
  local t = (nameOf(id) or "(no name - right click to set)") .. "  [" .. id .. "]"
  local p = prices[id]
  if p then
    t = t .. "\n" .. fmtGold(p.sell) .. " gp"
    if (p.weight or 0) > 0 then t = t .. "   " .. p.weight .. " oz   " .. fmtGold(math.floor(densityOf(id))) .. " gp/oz" end
    if p.npc and #p.npc > 0 then t = t .. "\nbest price seen at: " .. p.npc end
  else
    t = t .. "\nno price known yet"
  end
  return t
end

-- The client draws its own item tooltip (a root widget holding a label with id 'klasa') and it also swallows the
-- normal setTooltip path for items, so we hide theirs and draw our own box next to the cursor.
local tip

local function hideClientTooltip()
  if not data.ownTips then return end
  for _, c in ipairs(g_ui.getRootWidget():getChildren()) do
    if not c:isDestroyed() and c:isVisible() and c:getChildById('klasa') then c:hide() end
  end
end

local function hideTip()
  if tip then tip:hide() end
end

local function showTip(text)
  if not data.ownTips then return end
  if not tip then
    tip = g_ui.createWidget('AutolootTip', g_ui.getRootWidget())
    tip:setId('autolootTip')
  end
  tip:setText(text)
  tip:show()
  tip:raise()
  local pos, screen, size = g_window.getMousePosition(), g_window.getSize(), tip:getSize()
  local x = pos.x + 14
  local y = pos.y + 14
  if x + size.width > screen.width - 6 then x = pos.x - size.width - 8 end
  if y + size.height > screen.height - 6 then y = pos.y - size.height - 8 end
  tip:setPosition({ x = math.max(0, x), y = math.max(0, y) })
end

-- every item cell in this window uses our box, the client's tooltip is pushed out of the way
local function bindTip(widget, textFn)
  widget.onHoverChange = function(_, hovered)
    if hovered then
      showTip(textFn())
      addEvent(hideClientTooltip)
      scheduleEvent(hideClientTooltip, 60)
    else
      hideTip()
    end
  end
end

-- ui ------------------------------------------------------------------------------------
local refreshAll, refreshResults, refreshBags, selectBag

local function setStatus(text, color)
  window.status:setText(text or "")
  window.status:setColor(color or '#ffffff')
end

local function askName(id)
  modules.client_textedit.show(nameOf(id) or "", {title = "Item name as the server knows it (id " .. id .. ")"}, function(text)
    text = text:trim()
    data.customNames[tostring(id)] = text:len() > 0 and text or nil
    save()
    refreshAll()
  end)
end

local function bindClicks(w, id, onLeft)
  w.onMouseRelease = function(widget, mousePos, mouseButton)
    if mouseButton == MouseRightButton and id and id > 0 then askName(id) return true end
    if mouseButton == MouseLeftButton and onLeft then onLeft() return true end
    return false
  end
end

local function inList(list, id)
  for i, x in ipairs(list.items) do if x == id then return i end end
  return nil
end

local function addToActive(id)
  local list = activeList()
  if inList(list, id) then return setStatus(nameOf(id) or id .. " is already in " .. list.name, '#aaaaaa') end
  if #list.items >= SLOTS_PER_BAG then return setStatus(list.name .. " is full (" .. SLOTS_PER_BAG .. " slots)", RED) end
  table.insert(list.items, id)
  save()
  refreshBags()
  if #list.items > unlocked() then
    setStatus("slot " .. #list.items .. " is not unlocked on the server yet (" .. unlocked() .. " unlocked)", RED)
  else
    setStatus((nameOf(id) or id) .. " -> " .. list.name)
  end
end

local function removeFromActive(index)
  local list = activeList()
  if list.items[index] then
    table.remove(list.items, index)
    save()
    refreshBags()
  end
end

-- results grid
refreshResults = function()
  if not allItems then buildIndex() end
  window.results:destroyChildren()
  local q = window.search:getText():trim():lower()
  local hits = {}
  for _, id in ipairs(allItems) do
    local hit = true
    if q:len() > 0 then
      local n = nameOf(id)
      hit = (tostring(id):find(q, 1, true) == 1) or (n and n:lower():find(q, 1, true)) or false
    end
    if hit and data.pricedOnly and not prices[id] then hit = false end
    if hit then table.insert(hits, id) end
  end
  local sortMode = data.sort or 'name'
  if sortMode == 'value' or sortMode == 'density' then
    -- items with a known price first, best on top; everything unpriced keeps the name order behind them
    local key = (sortMode == 'value') and sellOf or densityOf
    table.sort(hits, function(a, b)
      local ka, kb = key(a), key(b)
      if ka ~= kb then return ka > kb end
      local na, nb = nameOf(a), nameOf(b)
      if na and nb and na ~= nb then return na < nb end
      if na and not nb then return true end
      if nb and not na then return false end
      return a < b
    end)
  end
  local total, shown = #hits, 0
  for _, id in ipairs(hits) do
    if shown >= MAX_RESULTS then break end
    shown = shown + 1
    local w = g_ui.createWidget('AutolootItem', window.results)
    w:setItemId(id)
    bindTip(w, function() return itemTooltip(id) end)
    bindClicks(w, id, function() addToActive(id) end)
  end
  local known = 0
  for _ in pairs(prices) do known = known + 1 end
  local priceNote
  if known == 0 then
    priceNote = " - no prices yet: open an NPC trade window once"
  else
    priceNote = " - prices for " .. known .. " items"
    if priceMeta.npc then
      priceNote = priceNote .. ", last from " .. priceMeta.npc ..
        (priceMeta.count > 0 and (" (" .. priceMeta.count .. " items") or " (") ..
        (ago(priceMeta.at) and ((priceMeta.count > 0 and ", " or "") .. ago(priceMeta.at)) or "") .. ")"
    end
  end
  if total == 0 then
    resultsSummary = "no match"
  elseif shown < total then
    resultsSummary = shown .. " of " .. total .. " shown, type to narrow down" .. priceNote
  else
    resultsSummary = total .. " items" .. priceNote
  end
  window.resultsInfo:setText(resultsSummary)
  window.resultsInfo:setColor('#aaaaaa')
end

-- one small backpack in the carousel
local function drawBackpack(index)
  local list = data.lists[index]
  local w = g_ui.createWidget('AutolootBackpack', window.carousel)
  w:setOn(index == data.active)
  w.name:setText(list.name)
  w.name:setTooltip(list.name)
  for i = 1, SLOTS_PER_BAG do
    local cell = g_ui.createWidget('AutolootMiniSlot', w.slots)
    local id = list.items[i]
    cell:setItemId(id or 0)
    if i > unlocked() then
      cell:setImageColor(id and RED or GREY)
      cell:setOpacity(0.5)
    end
    bindTip(cell, function()
      return id and itemTooltip(id) or ("slot " .. i .. (i > unlocked() and " (locked on the server)" or " (empty)"))
    end)
    cell.onMouseRelease = function(widget, mousePos, mouseButton)
      if mouseButton == MouseRightButton and id then askName(id) return true end
      if mouseButton ~= MouseLeftButton then return false end
      if id then
        data.active = index
        removeFromActive(i)
      else
        selectBag(index)
      end
      return true
    end
  end
  w.count:setText(#list.items .. "/" .. unlocked())
  w.onMouseRelease = function(widget, mousePos, mouseButton)
    selectBag(index); return true
  end
  return w
end

-- scroll the carousel so the selected bag is visible (only when the selection changes, so the arrows can
-- scroll away from it)
local function followSelection()
  if data.active < carouselStart then carouselStart = data.active end
  if data.active >= carouselStart + CAROUSEL_SIZE then carouselStart = data.active - CAROUSEL_SIZE + 1 end
end

selectBag = function(index)
  data.active = index
  save()
  followSelection()
  refreshBags()
end

local function saveServerAsBag()
  local ids = {}
  for _, e in ipairs(serverItems) do if e.id then table.insert(ids, e.id) end end
  local box
  box = displayGeneralBox("Save as backpack", "Copy the " .. #serverItems .. " item(s) the server currently loots into a new backpack?", {
    { text = tr('Yes'), callback = function()
        box:destroy()
        table.insert(data.lists, { name = "From server", items = ids })
        selectBag(#data.lists)
      end },
    { text = tr('No'), callback = function() box:destroy() end },
    anchor = AnchorHorizontalCenter }, nil, function() box:destroy() end)
end

local function drawServerCard()
  local w = g_ui.createWidget('AutolootServerBag', window.carousel)
  w:setOn(false)
  w.name:setText("On server")
  w.name:setTooltip("What the server loots right now (from its !autoloot reply). Click: save as a new backpack.")
  for i = 1, SLOTS_PER_BAG do
    local cell = g_ui.createWidget('AutolootMiniSlot', w.slots)
    local e = serverItems[i]
    cell:setItemId(e and e.id or 0)
    if e then
      bindTip(cell, function()
        if e.id then return itemTooltip(e.id) end
        return e.name .. "  (item id unknown - right click it in the list to set the name)"
      end)
    end
    if i > unlocked() then cell:setImageColor(GREY); cell:setOpacity(0.5) end
    cell.onMouseRelease = function() saveServerAsBag(); return true end
  end
  w.count:setText(#serverItems .. "/" .. (slotsMax or "?"))
  w.onMouseRelease = function() saveServerAsBag(); return true end
end

refreshBags = function()
  carouselStart = math.max(1, math.min(carouselStart, math.max(1, #data.lists - CAROUSEL_SIZE + 1)))
  window.carousel:destroyChildren()
  drawServerCard()
  for index = carouselStart, math.min(#data.lists, carouselStart + CAROUSEL_SIZE - 1) do drawBackpack(index) end
  window.prevBag:setEnabled(carouselStart > 1)
  window.nextBag:setEnabled(carouselStart + CAROUSEL_SIZE <= #data.lists)

  local list = activeList()
  local over = #list.items - unlocked()
  window.bagsLabel:setText("Backpacks - click a bag to select it, click an item in a bag to take it out. Server: " ..
    (slotsUsed or "?") .. "/" .. (slotsMax or "?") .. " slots in use, " .. unlocked() .. " unlocked" .. (slotsMax and "" or " (assumed)") ..
    (over > 0 and (". RED: " .. over .. " item(s) in '" .. list.name .. "' beyond your slots, the server will refuse them.") or "."))
end

refreshAll = function()
  refreshResults()
  refreshBags()
end

-- backpack management
local function newBag()
  modules.client_textedit.show("", {title = "New backpack name"}, function(text)
    text = text:trim()
    if text:len() == 0 then return end
    table.insert(data.lists, { name = text, items = {} })
    selectBag(#data.lists)
  end)
end

local function renameBag()
  modules.client_textedit.show(activeList().name, {title = "Rename backpack"}, function(text)
    text = text:trim()
    if text:len() == 0 then return end
    activeList().name = text
    save()
    refreshBags()
  end)
end

local function clearBagNow()
  activeList().items = {}
  save()
  refreshBags()
end

local function clearBag()
  local list = activeList()
  if #list.items == 0 then return end
  local box
  box = displayGeneralBox("Clear backpack", "Remove all " .. #list.items .. " item(s) from '" .. list.name .. "'?", {
    { text = tr('Yes'), callback = function() box:destroy() clearBagNow() end },
    { text = tr('No'), callback = function() box:destroy() end },
    anchor = AnchorHorizontalCenter }, nil, function() box:destroy() end)
end

local function deleteBag()
  if #data.lists == 1 then return clearBagNow() end
  local box
  box = displayGeneralBox("Delete backpack", "Delete '" .. activeList().name .. "' and its items?", {
    { text = tr('Yes'), callback = function()
        box:destroy()
        table.remove(data.lists, data.active)
        selectBag(math.max(1, math.min(#data.lists, data.active)))
      end },
    { text = tr('No'), callback = function() box:destroy() end },
    anchor = AnchorHorizontalCenter }, nil, function() box:destroy() end)
end

-- apply -------------------------------------------------------------------------------
local function pump()
  sendEvent = nil
  local next = table.remove(sendQueue, 1)
  if not next then return end
  g_game.talk(next.cmd)
  if next.progress then setStatus(next.progress) end
  if #sendQueue > 0 then sendEvent = scheduleEvent(pump, SEND_INTERVAL) end
end

local function apply()
  if not g_game.isOnline() then return setStatus("not online", RED) end
  if sendEvent then return setStatus("still sending, wait", '#ffdd55') end
  local list = activeList()
  local skipped = {}
  sendQueue = { { cmd = "!autoloot clear", progress = "clearing..." } }
  for i, id in ipairs(list.items) do
    local n = nameOf(id)
    if n then
      table.insert(sendQueue, { cmd = "!autoloot add " .. n, progress = "adding " .. i .. "/" .. #list.items .. ": " .. n })
    else
      table.insert(skipped, tostring(id))
    end
  end
  table.insert(sendQueue, { cmd = "!autoloot", progress = #skipped == 0 and ("done: " .. list.name) or ("done, skipped unnamed ids: " .. table.concat(skipped, ", ")) })
  pump()
end

-- single-command autoloot toggles for the item context menu and the tracker row menu
local function enqueueAutoloot(cmd, progress)
  table.insert(sendQueue, { cmd = cmd, progress = progress })
  if not sendEvent then pump() end
end

function isServerListed(id)
  local nm = nameOf(id)
  if not nm then return false end
  local low = nm:lower()
  for _, e in ipairs(serverItems) do
    if e.id == id or (e.name and e.name:lower() == low) then return true end
  end
  return false
end

function serverAdd(id)
  local nm = nameOf(id)
  if not nm or not g_game.isOnline() then return end
  enqueueAutoloot("!autoloot add " .. nm, "autoloot + " .. nm)
  enqueueAutoloot("!autoloot")
end

function serverRemove(id)
  local nm = nameOf(id)
  if not nm or not g_game.isOnline() then return end
  enqueueAutoloot("!autoloot remove " .. nm, "autoloot - " .. nm)
  enqueueAutoloot("!autoloot")
end

-- server replies ----------------------------------------------------------------------
-- "Autoloot: X/Y slotow." opens a short window in which the following line(s) list the items
-- (comma separated names, or "Lista jest pusta."). Names are mapped back to ids where known.
local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  local used, max = text:match(SLOTS_PATTERN)
  if used then
    slotsUsed, slotsMax = tonumber(used), tonumber(max)
    serverItems = {}
    collectUntil = g_clock.millis() + 1500
    if window and window:isVisible() then refreshBags() end
    return
  end
  if g_clock.millis() > collectUntil then return end
  if text:lower():find("pusta") then return end
  -- only the list line itself: "Lista: demonic essence, golden armor." (anything else in the window is noise)
  local body = text:match("^Lista:%s*(.+)$")
  if not body then return end
  collectUntil = 0
  for part in body:gmatch("[^,;\n]+") do
    local name = part:gsub("^%s+", ""):gsub("[%s%.]+$", "")
    if name:len() > 0 then
      local id = idOf(name)
      local dup = false
      for _, e in ipairs(serverItems) do if e.name:lower() == name:lower() then dup = true end end
      if not dup then table.insert(serverItems, { id = id, name = name }) end
    end
  end
  if window and window:isVisible() then refreshBags() end
end

-- add by value: fill the selected list with the best-paying items the price book knows ---
local function openByValue()
  local list = activeList()
  local w = g_ui.createWidget('AutolootValueWindow', g_ui.getRootWidget())
  local content = w.content
  local rows = {}
  local function row(label, value, tip)
    local r = g_ui.createWidget('AutolootValueRow', content)
    r.text:setText(label)
    r.value:setText(tostring(value))
    if tip then r.text:setTooltip(tip) end
    return r
  end
  rows.minSell = row('Min sell price', 1000, 'Only items an NPC pays at least this much for')
  rows.minDensity = row('Min gold per oz', 0, 'Value density: sell price divided by weight. 0 = ignore')
  rows.slots = row('Slots to fill', math.max(0, unlocked() - #list.items),
    'How many items to add. Your unlocked slot count is ' .. unlocked() .. ', the list holds ' .. #list.items .. ' now')
  local sortRow = g_ui.createWidget('AutolootValueRow', content)
  sortRow.text:setText('Order by')
  sortRow.value:destroy()
  local order = g_ui.createWidget('ComboBox', sortRow)
  order:addAnchor(AnchorLeft, 'text', AnchorRight)
  order:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
  order:setWidth(150)
  order:addOption('gold per oz', 'density')
  order:addOption('sell price', 'value')

  local known = 0
  for _ in pairs(prices) do known = known + 1 end
  w.info:setText(known == 0 and 'No prices yet: open an NPC trade window once and they are learned automatically.'
                             or (known .. ' items with known prices. Items already in the list are skipped.'))
  w.cancelButton.onClick = function() w:destroy() end
  w.okButton.onClick = function()
    local minSell = tonumber(rows.minSell.value:getText()) or 0
    local minDens = tonumber(rows.minDensity.value:getText()) or 0
    local slots = math.min(tonumber(rows.slots.value:getText()) or 0, SLOTS_PER_BAG - #list.items)
    local opt = order:getCurrentOption()
    local by = (opt and opt.data) or 'density'
    local cands = {}
    for id, p in pairs(prices) do
      if p.sell >= minSell and densityOf(id) >= minDens and not inList(list, id) then table.insert(cands, id) end
    end
    table.sort(cands, function(a, b)
      local ka, kb = (by == 'value') and sellOf(a) or densityOf(a), (by == 'value') and sellOf(b) or densityOf(b)
      if ka ~= kb then return ka > kb end
      return a < b
    end)
    local added = 0
    for _, id in ipairs(cands) do
      if added >= slots then break end
      table.insert(list.items, id)
      added = added + 1
    end
    save()
    refreshAll()
    w:destroy()
    setStatus(added .. ' item(s) added to ' .. list.name .. ' (' .. #cands .. ' matched)',
      added > 0 and '#66ff66' or RED)
  end
end

-- price book: every trade window teaches us what that NPC pays -------------------------
local function onOpenNpcTrade(items)
  local npc = (modules.game_npctrade and modules.game_npctrade.npcWindow and modules.game_npctrade.npcWindow:getText()) or 'an NPC'
  local learned, renamed = 0, 0
  for _, item in pairs(items) do
    local ptr, name, weight, sell = item[1], item[2], (item[3] or 0) / 100, item[5] or 0
    local id = ptr and ptr:getId()
    if id and sell > 0 then
      local p = prices[id]
      if not p or sell >= p.sell then
        prices[id] = { sell = sell, weight = weight, npc = npc, name = name }
        learned = learned + 1
      elseif p.name ~= name then
        p.name = name
        renamed = renamed + 1
      end
    end
  end
  if learned > 0 or renamed > 0 then
    priceMeta = { npc = npc, at = os.time(), count = learned }
    savePrices()
    nameIndex = nil -- shop names feed the search index
    if window and window:isVisible() then refreshAll() end
  end
end

-- for other modules (autoloot tracker) -------------------------------------------------
function priceInfo(id) return prices[id] end              -- { sell=, weight=, npc=, name= } or nil
function getServerItems() return serverItems end          -- { {id=, name=}, ... } from the last !autoloot reply
function getActiveItems() local l = activeList() return l.items, l.name end
function itemName(id) return nameOf(id) end

-- window ------------------------------------------------------------------------------
function show()
  followSelection()
  window:show()
  window:raise()
  window:focus()
  window.search:focus()
  refreshAll()
  if button then button:setOn(true) end
  if g_game.isOnline() and not sendEvent then g_game.talk("!autoloot") end
end

function hide()
  hideTip()
  window:hide()
  if button then button:setOn(false) end
end

function toggle()
  if window:isVisible() then hide() else show() end
end

function init()
  load()
  loadPrices()
  connect(g_game, { onTextMessage = onTextMessage, onOpenNpcTrade = onOpenNpcTrade,
                    onGameEnd = function() slotsUsed, slotsMax, serverItems = nil, nil, {} end })
  window = g_ui.displayUI('autoloot')
  window:hide()
  button = modules.client_topmenu.addRightGameToggleButton('autolootButton', tr('Autoloot'), '/images/topbuttons/coin', toggle, false, 1002)
  button:setOn(false)

  window.search.onTextChange = function() refreshResults() end
  for i, m in ipairs(SORT_MODES) do
    window.sort:addOption(m.text, m.id)
    if m.id == (data.sort or 'name') then window.sort:setCurrentIndex(i) end
  end
  window.sort.onOptionChange = function(_, _, dataId)
    data.sort = dataId or 'name'
    save()
    refreshResults()
  end
  window.byValue.onClick = openByValue
  window.ownTips:setChecked(data.ownTips and true or false)
  window.ownTips.onCheckChange = function(_, checked)
    data.ownTips = checked
    if not checked then hideTip() end
    save()
  end
  window.pricedOnly:setChecked(data.pricedOnly and true or false)
  window.pricedOnly.onCheckChange = function(_, checked)
    data.pricedOnly = checked
    save()
    refreshResults()
  end
  window.prevBag.onClick = function() carouselStart = math.max(1, carouselStart - 1); refreshBags() end
  window.nextBag.onClick = function() carouselStart = carouselStart + 1; refreshBags() end
  window.newBag.onClick = newBag
  window.renameBag.onClick = renameBag
  window.deleteBag.onClick = deleteBag
  window.clearBag.onClick = clearBag
  window.apply.onClick = apply
  window.onClose = hide

  local gi = modules.game_interface
  if gi and gi.addMenuHook then
    local function menuItemId(look, use)
      local t = use or look
      if t and t:isItem() and t:isPickupable() then return t:getId() end
    end
    gi.addMenuHook('autoloot', tr('Add to autoloot'),
      function(_, look, use) local id = menuItemId(look, use) if id then serverAdd(id) end end,
      function(_, look, use) local id = menuItemId(look, use) return id ~= nil and nameOf(id) ~= nil and not isServerListed(id) end)
    gi.addMenuHook('autoloot', tr('Remove from autoloot'),
      function(_, look, use) local id = menuItemId(look, use) if id then serverRemove(id) end end,
      function(_, look, use) local id = menuItemId(look, use) return id ~= nil and nameOf(id) ~= nil and isServerListed(id) end)
  end

  setStatus("")
end

function terminate()
  disconnect(g_game, { onTextMessage = onTextMessage, onOpenNpcTrade = onOpenNpcTrade })
  if modules.game_interface and modules.game_interface.removeMenuHook then
    modules.game_interface.removeMenuHook('autoloot')
  end
  removeEvent(sendEvent)
  if button then button:destroy() button = nil end
  if tip then tip:destroy() tip = nil end
  if window then window:destroy() window = nil end
end
