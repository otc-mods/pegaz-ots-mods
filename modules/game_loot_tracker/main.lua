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
-- items that never answer with a count (gear, weapons, arrows): read their number from equipment and open bags
local noProbe = {}
local lastGoods          -- { at=, count= } from the last NPC trade window (counts include closed bags)
local flipProbe = {}     -- id -> true: the other probe method (plain use vs use on yourself) after a silent try
local updateCounts       -- defined below, used by probe()
local showTip            -- defined below, used by probe()
local refreshEvent
local lastKey = ""
SORT_MODES = { "list", "name", "count", "value" }
SORT_LABELS = { list = "server order", name = "name", count = "count, highest first", value = "total value" }
local sortMode = "list"   -- g_settings 'lootTrackerSort'
-- our own item box on hover. Stored inverted ('lootTrackerTipsOff'): a missing or false key means enabled,
-- so a stale/half-written setting cannot silently switch it off.
local showTips = true
-- auto recount (optional, off by default): every AUTO_RECOUNT_MS while the window is open, plus after trades and
-- depot visits. Off = only the row clicks and the title-bar button. It uses every listed item once per round.
AUTO_RECOUNT_MS = 30000
local autoRecount = false -- g_settings 'lootTrackerAutoRecount'
local lastAutoRecount = 0

local applySort -- defined below, used by updateCounts

local function autoloot() return modules.game_autoloot end

-- prices come from the autoloot module's price book (learned from NPC trade windows)
local function priceOf(id)
  local al = autoloot()
  local p = al and al.priceInfo and al.priceInfo(id)
  return p and p.sell or nil
end

local function weightOf(id)
  local al = autoloot()
  local p = al and al.priceInfo and al.priceInfo(id)
  return p and p.weight or nil
end

local function fmtGold(n)
  if n >= 1000000 then return string.format('%.1fkk', n / 1000000) end
  if n >= 1000 then return string.format('%.1fk', n / 1000) end
  return tostring(math.floor(n))
end

-- the client draws its own item tooltip (a root widget holding a label with id 'klasa'): hide it over our rows
-- and draw our own box, same as the autoloot window does
local tip

local function hideClientTooltip()
  if not showTips then return end
  for _, c in ipairs(g_ui.getRootWidget():getChildren()) do
    if not c:isDestroyed() and c:isVisible() and c:getChildById('klasa') then c:hide() end
  end
end

local tipOwner  -- the row the box currently belongs to: a neighbour's leave event must not hide it

local function hideTip(widget)
  if widget and tipOwner and widget ~= tipOwner then return end
  tipOwner = nil
  if tip then tip:hide() end
end

local function makeTip()
  local ok, w = pcall(function() return g_ui.createWidget('LootTrackerTip', g_ui.getRootWidget()) end)
  if not ok or not w then -- style not registered (older install): build the same box in code
    w = g_ui.createWidget('UILabel', g_ui.getRootWidget())
    w:setBackgroundColor('#111111ee')
    w:setColor('#ffffff')
    w:setBorderWidth(1)
    w:setBorderColor('#666666')
    w:setTextAlign(AlignLeft)
    w:setPhantom(true)
  end
  w:setId('lootTrackerTip')
  return w
end

-- placed against the hovered row, not the mouse: widget coordinates are the same space as the root widget,
-- while the mouse position can be off under a scaled window
showTip = function(text, anchorWidget)
  if not showTips then return end
  if not tip or tip:isDestroyed() then tip = makeTip() end
  tip:setText(text)
  tip:resizeToText()
  tip:resize(tip:getWidth() + 10, tip:getHeight() + 6)
  tipOwner = anchorWidget
  tip:setOpacity(1)
  tip:show()
  tip:raise()
  local root = g_ui.getRootWidget()
  local rw, rh = root:getWidth(), root:getHeight()
  local size = tip:getSize()
  local m = g_window.getMousePosition()
  local x, y
  if m and m.x > 0 and m.y > 0 and m.x < rw and m.y < rh then
    x, y = m.x + 16, m.y + 16                                   -- next to the cursor
    if x + size.width > rw - 4 then x = m.x - size.width - 10 end
    if y + size.height > rh - 4 then y = m.y - size.height - 10 end
  elseif anchorWidget and not anchorWidget:isDestroyed() then    -- scaled window: mouse coords unusable
    x = anchorWidget:getX() - size.width - 6
    if x < 4 then x = anchorWidget:getX() + anchorWidget:getWidth() + 6 end
    y = anchorWidget:getY()
  else
    x, y = 20, 20
  end
  tip:setPosition({ x = math.max(4, math.min(x, rw - size.width - 4)),
                    y = math.max(4, math.min(y, rh - size.height - 4)) })
end

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

-- Hotkey use makes the server search every backpack and answer "Using one of N ...", closed bags included -
-- that is how the bot's icon labels count rings and amulets. A plain use is impossible for "use with" items
-- (a weapon would only open the crosshair), but the hotkey use-WITH packet gets the same count line, so those
-- are probed on ourselves, which is what a "use on yourself" hotkey does: "Using one of 6 noble axes...".
-- Not probed: runes (any target casts them) and fluid containers (they would pour out).
local function itemFlags(id)
  local okType, tt = pcall(function() return g_things.getThingType(id, ThingCategoryItem) end)
  if not okType or not tt then return false, false end
  local multi, fluid = false, false
  pcall(function() multi = tt:isMultiUse() end)
  pcall(function() fluid = tt:isFluidContainer() end)
  return multi, fluid
end

local function isRune(id)
  local n = nameOf(id)
  return n ~= nil and n:lower():find("rune", 1, true) ~= nil
end

local function reportsCount(id)
  local multi, fluid = itemFlags(id)
  if fluid or isRune(id) then return false end
  return true, multi
end

local function probe(id)
  if not g_game.isOnline() then return end
  local can, needsTarget = reportsCount(id)
  if flipProbe[id] then needsTarget = not needsTarget end -- the client's flags disagreed with the server: swap
  if noProbe[id] or not can then
    noProbe[id] = true
    -- the server only counts items it lets you "use": for gear and weapons we re-read what the client sees.
    -- Flash the number so the click is visibly answered, and say so when nothing is visible at all.
    local row = rows[id]
    if row then
      row.count:setText("...")
      row.count:setColor('#ffdd55')
    end
    scheduleEvent(function()
      updateCounts()
      if clientCount(id) == 0 and not known[id] then
        showTip((nameOf(id) or ("item " .. id)) ..
          "\nrunes and fluids are not counted: using them would cast or pour" ..
          "\nan open NPC trade window counts them, closed bags included", rows[id])
      end
    end, 150)
    return
  end
  pendingProbe = { id = id, due = g_clock.millis() + 1500, target = needsTarget }
  local row = rows[id]
  if row then row.count:setText("..."); row.count:setColor('#ffdd55') end -- asking the server
  if needsTarget then
    -- "use on yourself" is what a hotkey does for use-with items: the server prints the count first and then
    -- refuses the action itself, so a weapon or a shield is counted without any side effect
    local me = g_game.getLocalPlayer()
    if not me then return end
    g_game.useInventoryItemWith(id, me, 0)
  else
    g_game.useInventoryItem(id)
  end
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

updateCounts = function()
  -- a probe that got no answer: keep whatever we knew (an answer can be late or lost), never invent a 0.
  -- Silence also means the method was wrong for this item, so the next click tries the other one.
  if pendingProbe and pendingProbe.due <= g_clock.millis() then
    local p = pendingProbe
    pendingProbe = nil
    if not known[p.id] then
      if flipProbe[p.id] then noProbe[p.id] = true else flipProbe[p.id] = true end
    end
  end
  for id, row in pairs(rows) do
    if id == "order" then goto continue end
    if pendingProbe and pendingProbe.id == id then goto continue end -- keep the "..." until the answer or timeout
    if row.name:getText() == row.fullName or row.name:getText():sub(-3) == "..." then fitName(row) end
    local client = clientCount(id)
    local est = estimate(id)
    -- server-confirmed number wins; for items that cannot be used the client's own view of equipment and open
    -- bags is the best we get (grey, since closed bags are invisible); "?" only when we know nothing at all
    local text, fromClient = "?", false
    if est then
      text = tostring(est)
    elseif client > 0 then
      text, fromClient = tostring(client), true
    end
    row.count:setText(text)
    local k = known[id]
    local fresh = k and (g_clock.millis() - k.t) < 10 * 60 * 1000
    row.count:setColor((fresh and not fromClient) and '#ffffff' or '#c8c8c8')
    -- price first: that is what the box is for
    local price = priceOf(id)
    local lines = { nameOf(id) or ("item " .. id) }
    if price then
      table.insert(lines, fmtGold(price) .. " gp each")
      local w = weightOf(id)
      if w and w > 0 then table.insert(lines, fmtGold(price / w) .. " gp/oz") end
      local n = est or (client > 0 and client or nil)
      if n then
        local src = ""
        if not est and client > 0 then src = ", open bags only"
        elseif noProbe[id] and est then src = ", from a trade window"
        end
        table.insert(lines, "total " .. fmtGold(price * n) .. " gp  (" .. n .. " x" .. src .. ")")
      end
    else
      table.insert(lines, "no NPC price known yet")
    end
    row.tipText = table.concat(lines, "\n")
    ::continue::
  end
  if sortMode == "count" or sortMode == "value" then applySort() end
end

local function shownCount(id)
  return estimate(id) or -1 -- unknown sorts last
end

local function shownValue(id)
  local price, est = priceOf(id), estimate(id)
  if not price or not est then return -1 end
  return price * est
end

applySort = function()
  local ordered = {}
  for id, row in pairs(rows) do if id ~= "order" then table.insert(ordered, id) end end
  if sortMode == "name" then
    table.sort(ordered, function(a, b) return (nameOf(a) or tostring(a)):lower() < (nameOf(b) or tostring(b)):lower() end)
  elseif sortMode == "value" then
    table.sort(ordered, function(a, b)
      local va, vb = shownValue(a), shownValue(b)
      if va ~= vb then return va > vb end
      return (nameOf(a) or tostring(a)):lower() < (nameOf(b) or tostring(b)):lower()
    end)
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

function toggleAutoRecount()
  if autoRecount then
    autoRecount = false
    g_settings.set('lootTrackerAutoRecount', false)
    return
  end
  local box
  box = displayGeneralBox(tr('Auto recount'),
    tr('Every ' .. math.floor(AUTO_RECOUNT_MS / 1000) .. ' seconds (and after trades and depot visits) the tracker uses each listed item once to read its count.\n' ..
       'Gear and gold are fine, but food, potions and scripted items (scrolls, removers) get used up.\n\nEnable?'),
    { { text = tr('Enable'), callback = function() box:destroy() autoRecount = true g_settings.set('lootTrackerAutoRecount', true) end },
      { text = tr('Cancel'), callback = function() box:destroy() end },
      anchor = AnchorHorizontalCenter }, nil, function() box:destroy() end)
end

-- title-bar arrow: popup with the sort choices (filters go here later)
function showMenu()
  local menu = g_ui.createWidget('PopupMenu')
  for _, m in ipairs(SORT_MODES) do
    menu:addOption((m == sortMode and "* " or "  ") .. "Sort by " .. SORT_LABELS[m], function() setSort(m) end)
  end
  menu:addSeparator()
  menu:addOption((autoRecount and "[x] " or "[ ] ") .. "Auto recount every " .. math.floor(AUTO_RECOUNT_MS / 1000) .. "s", toggleAutoRecount)
  menu:addOption((showTips and "[x] " or "[ ] ") .. "Item info on hover", function()
    showTips = not showTips
    g_settings.set('lootTrackerTipsOff', not showTips)
    if not showTips then hideTip() end
  end)
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
      row.onHoverChange = function(widget, hovered)
        if hovered then
          showTip(widget.tipText or (nameOf(id) or ("item " .. id)), widget)
          addEvent(hideClientTooltip)
          scheduleEvent(hideClientTooltip, 60)
        else
          hideTip(widget)
        end
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

local CANNOT_USE = { 'cannot use', 'nie mozesz', 'nie mo\197\188esz', 'nie da si' }

local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  if pendingProbe then
    local low = text:lower()
    for _, pat in ipairs(CANNOT_USE) do
      if low:find(pat, 1, true) then -- this item never reports a count: stop asking, use the client's view
        noProbe[pendingProbe.id] = true
        pendingProbe = nil
        updateCounts()
        return
      end
    end
  end
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
-- An open NPC trade window is the only place the server tells us how many of an item we own INCLUDING closed
-- bags (it answers for every item that NPC buys), so those numbers are the ground truth for gear and weapons.
local function onPlayerGoods(money, items)
  local n = 0
  for _, it in pairs(items or {}) do
    local id = it[1] and it[1]:getId()
    if id and rows[id] then confirm(id, it[2] or 0) n = n + 1 end
  end
  if n > 0 then lastGoods = { at = g_clock.millis(), count = n } end
  updateCounts()
end

local function onCloseNpcTrade()
  if not autoRecount then return end
  scheduleEvent(function() if window and window:isVisible() then refreshAll() end end, 1500)
end

-- depot closed: items may have moved out of sight -> recount
local function onContainerClose(container)
  if not autoRecount then return end
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
  for id, row in pairs(rows) do -- visible answer to the click, also for rows that cannot be probed
    if id ~= "order" then row.count:setText("...") row.count:setColor('#ffdd55') end
  end
  scheduleEvent(updateCounts, 150)
  refreshQueue = {}
  for _, id in ipairs(rows.order or {}) do
    if not noProbe[id] then table.insert(refreshQueue, id) end
  end
  if #refreshQueue > 0 and not refreshEvent2 then refreshStep() end
end

local function tick()
  if g_game.isOnline() then
    rebuild()
    if autoRecount and window and window:isVisible() and #refreshQueue == 0 and g_clock.millis() - lastAutoRecount >= AUTO_RECOUNT_MS then
      lastAutoRecount = g_clock.millis()
      refreshAll()
    end
  end
  refreshEvent = scheduleEvent(tick, REFRESH_MS)
end

-- console helper: modules.game_loot_tracker.tipTest()
function tipTest()
  showTips = true
  showTip('tip test\nline two', window)
  local kids = g_ui.getRootWidget():getChildren()
  local idx = 0
  for i, c in ipairs(kids) do if c == tip then idx = i end end
  print('tip:', tip:getX() .. ',' .. tip:getY(), tip:getWidth() .. 'x' .. tip:getHeight(),
        'visible', tostring(tip:isVisible()), 'opacity', tip:getOpacity(),
        'root child', idx .. '/' .. #kids, 'text len', #tip:getText())
  print('last root children:', (kids[#kids] and kids[#kids]:getId() or '-'), (kids[#kids-1] and kids[#kids-1]:getId() or '-'))
end

function toggle()
  if window:isVisible() then window:close() else window:open() end
end

function onMiniWindowClose()
  if button then button:setOn(false) end
end

function init()
  if g_settings.exists('lootTrackerSort') then sortMode = g_settings.getString('lootTrackerSort') end
  if g_settings.exists('lootTrackerAutoRecount') then autoRecount = g_settings.getBoolean('lootTrackerAutoRecount') end
  showTips = not g_settings.getBoolean('lootTrackerTipsOff')
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
  if tip then tip:destroy() tip = nil end
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
end
