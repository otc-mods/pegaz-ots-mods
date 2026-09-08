-- Autoloot tracker: a Stats-like mini-window listing the items the server currently loots (from the autoloot
-- module's last "!autoloot" reply, else the selected backpack) with sprite, name and how many you carry.
-- Count = equipment + open containers, replaced by the server's "Using one of N ..." figure when one arrives.
-- Clicking a row sends a count probe (uses the item once - harmless for loot, do not use on potions).
-- Counts only move on facts: a server line or the client seeing more. No answer = last value stays.

REFRESH_MS = 2000
MIN_CONTENT = 40
MAX_CONTENT = 700

local window, contents, button
local rows = {}          -- id -> row widget
-- known[id] = { n = count the server confirmed, clientAt = what the client saw at that moment, t = when }
-- shown value = n only. Open containers are NOT mixed in: a recount taken with a bag open and the bag closed
-- later would read as a loss. Counts move on server facts only (probe, use line, NPC trade list).
local known = {}
local pendingProbe       -- { id=, due= }
local refreshEvent
local lastKey = ""
SORT_MODES = { "list", "name", "count" }
SORT_LABELS = { list = "server order", name = "name", count = "count, highest first" }
local sortMode = "list"   -- g_settings 'lootTrackerSort'
AUTO_RECOUNT_MS = 30000   -- recount everything this often while the window is open, plus after trades and depot visits
local lastAutoRecount = 0

local applySort -- defined below, used by updateCounts

local function autoloot() return modules.game_autoloot end

local function currentItems()
  local al = autoloot()
  if not al then return {}, "no autoloot module" end
  local server = al.getServerItems and al.getServerItems() or {}
  if #server > 0 then
    local ids = {}
    for _, e in ipairs(server) do if e.id then table.insert(ids, e.id) end end
    return ids, "on server"
  end
  local items, name = al.getActiveItems()
  return items or {}, name or "backpack"
end

local function nameOf(id)
  local al = autoloot()
  return (al and al.itemName and al.itemName(id)) or nil
end

local function clientCount(id)
  local n = 0
  local me = g_game.getLocalPlayer()
  if not me then return 0 end
  for slot = 1, 10 do -- head .. ammo
    local it = me:getInventoryItem(slot)
    if it and it:getId() == id then n = n + it:getCount() end
  end
  for _, c in pairs(g_game.getContainers()) do
    for _, it in ipairs(c:getItems()) do
      if it:getId() == id then n = n + it:getCount() end
    end
  end
  return n
end

-- resizable freely: small enough to scroll, large enough to leave empty space below the list
local function fitHeight()
  window:setContentMinimumHeight(MIN_CONTENT)
  window:setContentMaximumHeight(MAX_CONTENT)
  if window:getHeight() < window:getMinimumHeight() then window:setHeight(window:getMinimumHeight()) end
end

local function confirm(id, n)
  known[id] = { n = math.max(0, n), clientAt = clientCount(id), t = g_clock.millis() }
end

local function estimate(id)
  local k = known[id]
  if not k then return nil end
  return math.max(0, k.n)
end

local function probe(id)
  if not g_game.isOnline() then return end
  pendingProbe = { id = id, due = g_clock.millis() + 1500 }
  local row = rows[id]
  if row then row.count:setText("..."); row.count:setColor('#ffdd55') end -- asking the server
  g_game.useInventoryItem(id)
end

-- cut a name that does not fit its label, with "..." (labels do not do this on their own)
local function fitName(row)
  local full = row.fullName or ""
  local width = row.name:getWidth()
  if width <= 0 then return end
  row.name:setText(full)
  if row.name:getTextSize().width <= width then return end
  local n = #full
  while n > 1 do
    n = n - 1
    row.name:setText(full:sub(1, n) .. "...")
    if row.name:getTextSize().width <= width then return end
  end
end

local function updateCounts()
  -- a probe that got no answer: keep whatever we knew (an answer can be late or lost), never invent a 0
  if pendingProbe and pendingProbe.due <= g_clock.millis() then
    pendingProbe = nil
  end
  for id, row in pairs(rows) do
    if id == "order" then goto continue end
    if pendingProbe and pendingProbe.id == id then goto continue end -- keep the "..." until the answer or timeout
    if row.name:getText() == row.fullName or row.name:getText():sub(-3) == "..." then fitName(row) end
    local client = clientCount(id)
    local est = estimate(id)
    -- "?" = nothing confirmed yet; click the row to ask the server (open bags are deliberately not shown as the count)
    local text = est and tostring(est) or "?"
    row.count:setText(text)
    local k = known[id]
    local fresh = k and (g_clock.millis() - k.t) < 10 * 60 * 1000
    row.count:setColor(fresh and '#ffffff' or '#c8c8c8')
    row:setTooltip((nameOf(id) or ("item " .. id)) .. "\nin equipment and open bags: " .. client ..
      (k and ("\nserver confirmed: " .. k.n .. " (" .. math.floor((g_clock.millis() - k.t) / 60000) .. " min ago)") or "\nnot confirmed yet") ..
      "\nclick: recount (uses the item once)")
    ::continue::
  end
  if sortMode == "count" then applySort() end
end

local function shownCount(id)
  return estimate(id) or -1 -- unknown sorts last
end

applySort = function()
  local ordered = {}
  for id, row in pairs(rows) do if id ~= "order" then table.insert(ordered, id) end end
  if sortMode == "name" then
    table.sort(ordered, function(a, b) return (nameOf(a) or tostring(a)):lower() < (nameOf(b) or tostring(b)):lower() end)
  elseif sortMode == "count" then
    table.sort(ordered, function(a, b)
      local ca, cb = shownCount(a), shownCount(b)
      if ca ~= cb then return ca > cb end
      return (nameOf(a) or tostring(a)):lower() < (nameOf(b) or tostring(b)):lower()
    end)
  else
    local pos = {}
    for i, id in ipairs(rows.order or {}) do pos[id] = i end
    table.sort(ordered, function(a, b) return (pos[a] or 0) < (pos[b] or 0) end)
  end
  for i, id in ipairs(ordered) do contents:moveChildToIndex(rows[id], i) end
end

local function setSort(mode)
  sortMode = mode
  g_settings.set('lootTrackerSort', sortMode)
  applySort()
end

-- title-bar arrow: popup with the sort choices (filters go here later)
function showMenu()
  local menu = g_ui.createWidget('PopupMenu')
  for _, m in ipairs(SORT_MODES) do
    menu:addOption((m == sortMode and "* " or "  ") .. "Sort by " .. SORT_LABELS[m], function() setSort(m) end)
  end
  local b = window:getChildById('menuButton')
  menu:display({ x = b:getX(), y = b:getY() + b:getHeight() })
end

local function rebuild()
  if not window then return end
  local ids, source = currentItems()
  local key = source .. ":" .. table.concat(ids, ",")
  if key ~= lastKey then
    lastKey = key
    contents:destroyChildren()
    rows = {}
    rows.order = ids
    if #ids == 0 then
      local l = g_ui.createWidget('Label', contents)
      l:setText("Autoloot list is empty.\nAdd items in the Autoloot window.")
      l:setTextWrap(true)
      l:setTextAlign(AlignCenter)
      l:setHeight(44)
    end
    for _, id in ipairs(ids) do
      local row = g_ui.createWidget('LootTrackerRow', contents)
      row.item:setItemId(id)
      row.fullName = nameOf(id) or "(no name)"
      row.name:setText(row.fullName)
      row.itemId:setText("id " .. id)
      row.onMouseRelease = function(widget, mousePos, mouseButton)
        if mouseButton == MouseLeftButton or mouseButton == MouseRightButton then probe(id) return true end
        return false
      end
      rows[id] = row
    end
    applySort()
    fitHeight()
  end
  updateCounts()
end

-- server "Using one of 12 gold coins..." / "Using the last gold coin..." -----------------------
local function idFromName(name)
  local al = autoloot()
  if not al or not al.AutolootNames then return nil end
  local low = name:lower()
  local cands = { low, (low:gsub("s$", "")), (low:gsub("es$", "")), (low:gsub("ies$", "y")) }
  for id in pairs(rows) do
    local n = id ~= "order" and nameOf(id) or nil
    if n then
      local nl = n:lower()
      for _, c in ipairs(cands) do if c == nl then return id end end
    end
  end
  return nil
end

-- does the server's (plural) name belong to this item? nil when the item has no known name
local function nameBelongs(reported, id)
  local n = nameOf(id)
  if not n then return nil end
  local r, k = reported:lower(), n:lower()
  return r == k or r == k .. "s" or r == k .. "es" or r:gsub("s$", "") == k or r:gsub("es$", "") == k or r:gsub("ies$", "y") == k
end

local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  local count, name = text:match("^Using one of (%d+) (.+)%.%.%.$")
  if not count then
    name = text:match("^Using the last (.+)%.%.%.$")
    if name then count = 1 end
  end
  if not name then return end
  count = tonumber(count)
  local id = idFromName(name)
  if pendingProbe and pendingProbe.due > g_clock.millis() then
    local belongs = nameBelongs(name, pendingProbe.id)
    -- the probe's answer must name the probed item; an item without any known name accepts an unmatched line
    if belongs == true or (belongs == nil and id == nil) then
      confirm(pendingProbe.id, count)                -- probe answer: nothing consumed
      pendingProbe = nil
      updateCounts()
      return
    end
  end
  if id then confirm(id, count - 1) end             -- somebody's real use: one consumed
  updateCounts()
end

-- NPC trade: the server sends exact totals of everything the NPC buys -> confirm those; and after the trade
-- window closes, recount the list (selling changed numbers we could not see)
local function onPlayerGoods(money, items)
  for _, it in pairs(items or {}) do
    local id = it[1] and it[1]:getId()
    if id and rows[id] then confirm(id, it[2] or 0) end
  end
  updateCounts()
end

local function onCloseNpcTrade()
  scheduleEvent(function() if window and window:isVisible() then refreshAll() end end, 1500)
end

-- depot closed: items may have moved out of sight -> recount
local function onContainerClose(container)
  local name = container and container:getName() or ""
  if name:lower():find("depot") or name:lower():find("locker") then
    scheduleEvent(function() if window and window:isVisible() then refreshAll() end end, 1000)
  end
end

-- refresh all: probe the rows one after another, 700 ms apart (each probe needs its own answer)
local refreshQueue, refreshEvent2 = {}, nil
local function refreshStep()
  refreshEvent2 = nil
  if pendingProbe and pendingProbe.due > g_clock.millis() then
    refreshEvent2 = scheduleEvent(refreshStep, 300)
    return
  end
  local id = table.remove(refreshQueue, 1)
  if not id then return end
  if rows[id] then probe(id) end
  if #refreshQueue > 0 then refreshEvent2 = scheduleEvent(refreshStep, 700) end
end

function refreshAll()
  refreshQueue = {}
  for _, id in ipairs(rows.order or {}) do table.insert(refreshQueue, id) end
  if #refreshQueue > 0 and not refreshEvent2 then refreshStep() end
end

local function tick()
  if g_game.isOnline() then
    rebuild()
    if window and window:isVisible() and #refreshQueue == 0 and g_clock.millis() - lastAutoRecount >= AUTO_RECOUNT_MS then
      lastAutoRecount = g_clock.millis()
      refreshAll()
    end
  end
  refreshEvent = scheduleEvent(tick, REFRESH_MS)
end

function toggle()
  if window:isVisible() then window:close() else window:open() end
end

function onMiniWindowClose()
  if button then button:setOn(false) end
end

function init()
  if g_settings.exists('lootTrackerSort') then sortMode = g_settings.getString('lootTrackerSort') end
  connect(g_game, { onTextMessage = onTextMessage, onPlayerGoods = onPlayerGoods, onCloseNpcTrade = onCloseNpcTrade,
                    onGameEnd = function() known = {} end })
  connect(Container, { onClose = onContainerClose })
  local root = modules.game_interface.getRootPanel()
  local parent = root:recursiveGetChildById('leftPanel2') or modules.game_interface.getLeftPanel()
  window = g_ui.loadUI('tracker', parent)
  contents = window:getChildById('contentsPanel')
  button = modules.client_topmenu.addRightGameToggleButton('lootTrackerButton', tr('Autoloot tracker'), '/images/topbuttons/motd', toggle, false, 1004)
  window.onOpen = function() if button then button:setOn(true) end end
  window:setup()
  if button then button:setOn(window:isVisible()) end
  lastKey = ""
  tick()
end

function terminate()
  disconnect(g_game, { onTextMessage = onTextMessage, onPlayerGoods = onPlayerGoods, onCloseNpcTrade = onCloseNpcTrade })
  disconnect(Container, { onClose = onContainerClose })
  removeEvent(refreshEvent)
  removeEvent(refreshEvent2)
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
end
