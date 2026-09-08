-- Autoloot GUI: named loot lists drawn as 15-slot backpacks, item search over the client's pickupable
-- item types, Apply = "!autoloot clear" + "!autoloot add <name>" per item. Unlocked slot count comes from
-- the server's "Autoloot: X/Y slotow." reply. Names: items_860.lua (AutolootNames) + user-set names.

MAX_RESULTS = 300
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
local sendQueue, sendEvent = {}, nil

-- persistence -----------------------------------------------------------------------
local function save() g_settings.setNode('autoloot', data) end

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
  data = { lists = {}, active = 1, customNames = {} }
  if type(raw) == 'table' then
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
local function nameOf(id) return data.customNames[tostring(id)] or AutolootNames[id] end

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

local function itemTooltip(id)
  return (nameOf(id) or "(no name - right click to set)") .. "  [" .. id .. "]"
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
  local shown, total = 0, 0
  for _, id in ipairs(allItems) do
    local hit = true
    if q:len() > 0 then
      local n = nameOf(id)
      hit = (tostring(id):find(q, 1, true) == 1) or (n and n:lower():find(q, 1, true)) or false
    end
    if hit then
      total = total + 1
      if shown < MAX_RESULTS then
        shown = shown + 1
        local w = g_ui.createWidget('AutolootItem', window.results)
        w:setItemId(id)
        w:setTooltip(itemTooltip(id))
        bindClicks(w, id, function() addToActive(id) end)
      end
    end
  end
  if total == 0 then
    window.resultsInfo:setText("no match")
  elseif shown < total then
    window.resultsInfo:setText(shown .. " of " .. total .. " shown - type to narrow down")
  else
    window.resultsInfo:setText(total .. " items")
  end
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
    cell:setTooltip(id and itemTooltip(id) or ("slot " .. i .. (i > unlocked() and " (locked)" or "")))
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
    if e then cell:setTooltip(e.name .. (e.id and ("  [" .. e.id .. "]") or "  (unknown item name)")) end
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
  local body = text:gsub("^[^:]*:%s*", "")          -- drop a "Lista: " style prefix
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

-- for other modules (autoloot tracker) -------------------------------------------------
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
  window:hide()
  if button then button:setOn(false) end
end

function toggle()
  if window:isVisible() then hide() else show() end
end

function init()
  load()
  connect(g_game, { onTextMessage = onTextMessage, onGameEnd = function() slotsUsed, slotsMax, serverItems = nil, nil, {} end })
  window = g_ui.displayUI('autoloot')
  window:hide()
  button = modules.client_topmenu.addRightGameToggleButton('autolootButton', tr('Autoloot'), '/images/topbuttons/shop', toggle, false, 1002)
  button:setOn(false)

  window.search.onTextChange = function() refreshResults() end
  window.prevBag.onClick = function() carouselStart = math.max(1, carouselStart - 1); refreshBags() end
  window.nextBag.onClick = function() carouselStart = carouselStart + 1; refreshBags() end
  window.newBag.onClick = newBag
  window.renameBag.onClick = renameBag
  window.deleteBag.onClick = deleteBag
  window.clearBag.onClick = clearBag
  window.apply.onClick = apply
  window.onClose = hide
  setStatus("")
end

function terminate()
  disconnect(g_game, { onTextMessage = onTextMessage })
  removeEvent(sendEvent)
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
end
