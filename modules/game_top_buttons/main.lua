-- Better top buttons: a MiniWindow in the right panel listing game buttons as [real icon] + name. Every button
-- has one of three tiers:
--   fav  - stays an icon in the client's old Buttons grid (quick access, shown above this panel)
--   list - a row in this panel (the default)
--   off  - not shown anywhere
-- Rows hold the ACTUAL button widget, so the real icon draws itself and clicks work natively. Buttons are handed
-- back to their home panel on unload, so uninstalling restores stock behaviour.
local ROW_H, BASE_H, SEARCH_H = 22, 26, 23
local MAX_FAVS = 6                  -- the favourites window never scrolls, so it holds what fits

local window, rowsPanel, settingsBtn, settingsWin
local searchBox, filter = nil, ''   -- the search box filters list rows; empty means show everything
local madeFocusable = {}            -- ancestors we flipped so the keyboard can actually reach the box
local hijacked = false
local favFull = 0
local adopted = {}          -- { { btn = widget, home = original parent } }
local fav, off = {}, {}     -- id -> true
local favsWindow            -- favourites get their own mini window, so the list can be minimised
local favsPanel             -- the icon grid inside it
local tickEvent, grabEvent, focusEvent, settingsSweep
local focusTrail, lastFocusLine = {}, nil
local lastListed, shownRows = -1, -1
local lastSig = nil
local sizedOnce = false


local function collapsed()
  local ok, v = pcall(function() return window and window:isOn() end)
  return (ok and v) and true or false
end

-- While collapsed the miniwindow owns its own height (minimizedHeight) and hides its contents. Setting our own
-- height there is exactly what produced the tall empty box: contents hidden, frame stretched back open.
local function fitHeight()
  if not window then return end
  if collapsed() then
    -- collapsed: minimize() owns the height. Snap back if an earlier build stretched it open.
    local mh = window.minimizedHeight or 24
    if window:getHeight() ~= mh then pcall(function() window:minimize(true) end) end
    return
  end
  -- expanded: the user owns the height. We only pick one when the window has never been sized, because
  -- UIMiniWindow:maximize() and the container's fitAll() also set it - three writers is what made it jump.
  if sizedOnce then return end
  sizedOnce = true
  if window:getSettings('height') then return end
  local want = BASE_H + SEARCH_H + math.max(shownRows, 0) * ROW_H
  window:setHeight(math.min(want, 320))
end

-- widget:focus() only moves focus inside its own parent, so a box three levels deep never actually gets the
-- keyboard. Walk the chain to the root instead.
local function focusChain(w)
  while w do
    local p = w:getParent()
    if p then p:focusChild(w, ActiveFocusReason) end
    w = p
  end
end

-- Keyboard focus can only reach a widget when every ancestor is focusable - but leaving the right panel
-- focusable meant any click there stole focus from the console, and Tab (bound on the console panel) stopped
-- switching channels. So the path is opened only while the search box is actually in use.
local function openFocusPath(w)
  w = w and w:getParent()
  while w do
    if not w:isFocusable() then
      w:setFocusable(true)
      table.insert(madeFocusable, w)
    end
    w = w:getParent()
  end
end

local function closeFocusPath()
  for _, w in ipairs(madeFocusable) do
    if w and not w:isDestroyed() then w:setFocusable(false) end
  end
  madeFocusable = {}
end

local function pointerOver(w)
  if not w or w:isDestroyed() or not w:isVisible() then return false end
  local p = g_window.getMousePosition()
  return p.x >= w:getX() and p.x < w:getX() + w:getWidth()
     and p.y >= w:getY() and p.y < w:getY() + w:getHeight()
end

-- Walking is bound with alwaysCall, so a focused text box does not stop WSAD by itself. We take the keyboard
-- only on a real click and give it back the moment the box is done with it - a stuck grab means the player
-- cannot walk or talk, which is far worse than a lost keystroke.
local function grabKeyboard(w)
  if w then focusChain(w) end
  if hijacked then return end
  hijacked = true
  local walking = modules.game_walking
  if walking and walking.disableWSAD then walking.disableWSAD() end
end

-- UITextEdit handles its own mouse press in C++, so our onMousePress hook never fired and the grab never
-- started. Polling the box's focus state is the one signal that cannot be missed.
local function syncGrab()
  if not searchBox or searchBox:isDestroyed() then return end
  if not hijacked then
    -- a click inside the box is the only thing that takes the keyboard (UITextEdit swallows onMousePress in
    -- C++, so watching the pointer is the only reliable signal)
    local clicked = g_mouse.isPressed(MouseLeftButton) and pointerOver(searchBox)
    if searchBox:isVisible() and not collapsed() and (clicked or searchBox:isFocused()) then
      openFocusPath(searchBox)
      grabKeyboard(searchBox)
    end
  elseif not searchBox:isVisible() or collapsed() or not searchBox:isFocused() then
    releaseKeyboard()
  end
end

function releaseKeyboard()
  if not hijacked then return end
  hijacked = false
  local walking = modules.game_walking
  if walking and walking.enableWSAD then walking.enableWSAD() end
  -- focusing the game panel is not enough: the box keeps focus inside its own parent, so clear that first
  if searchBox and not searchBox:isDestroyed() then
    local p = searchBox:getParent()
    if p then pcall(function() p:focusChild(nil, ActiveFocusReason) end) end
  end
  closeFocusPath()
  -- hand the keyboard back to the chat: Tab is bound on the console panel, so leaving focus anywhere else
  -- silently kills channel switching until the player clicks the chat
  local console = modules.game_console
  local edit = console and console.consoleTextEdit
  if edit and not edit:isDestroyed() then
    focusChain(edit)
  else
    local root = modules.game_interface.getRootPanel()
    if root then focusChain(root) end
  end
end

-- our two windows sit right under the map, health bar and equipment - above the battle list, containers and
-- everything else the client keeps adding below them
local KEEP_ABOVE = { 'minimapWindow', 'healthInfoWindow', 'inventoryWindow' }
local function ensureOrder()
  local panel = modules.game_interface.getRightPanel()
  if not panel or not panel.moveChildToIndex then return end
  local wanted = { favsWindow, window }
  local at = 1
  for _, id in ipairs(KEEP_ABOVE) do
    local w = panel:getChildById(id)
    if w then at = math.max(at, panel:getChildIndex(w) + 1) end
  end
  for _, w in ipairs(wanted) do
    if w and not w:isDestroyed() and w:getParent() == panel then
      if panel:getChildIndex(w) ~= at then pcall(function() panel:moveChildToIndex(w, at) end) end
      at = at + 1
    end
  end
end

local function gb() return modules.game_buttons end

local function tierOf(id)
  if fav[id] then return 'fav' end
  if off[id] then return 'off' end
  return 'list'
end

-- g_settings hands arrays back as "1:", "2:" child nodes with STRING keys, so ipairs() over them yields nothing -
-- that is why the tiers looked wiped after every reload. These are sets, so order does not matter: take values.
local function idsFrom(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for _, v in pairs(t) do
    if type(v) == 'string' and v ~= '' then table.insert(out, v) end
  end
  return out
end

local function load()
  fav, off = {}, {}
  local node = g_settings.getNode('topButtons')
  if node then
    local n = 0
    for _, id in ipairs(idsFrom(node.fav)) do
      if n < MAX_FAVS then fav[id] = true n = n + 1 end   -- older settings may hold more than the cap
    end
    for _, id in ipairs(idsFrom(node.off)) do off[id] = true end
    for _, id in ipairs(idsFrom(node.hidden)) do off[id] = true end  -- migrate the old single "hidden" list
  end
end

local function save()
  local f, o = {}, {}
  for id in pairs(fav) do table.insert(f, id) end
  for id in pairs(off) do table.insert(o, id) end
  g_settings.setNode('topButtons', { fav = f, off = o })
  g_settings.save()   -- settings are otherwise only flushed on exit; a crash or kill would lose the tiers
end

-- readable name from the widget id ("bagOrganizerButton" -> "Bag Organizer"); tooltips are often whole sentences
local function prettyName(w)
  local id = (w:getId() or ''):gsub('Button$', '')
  if id ~= '' then
    local s = id:gsub('(%l)(%u)', '%1 %2'):gsub('(%a)([%u][%l])', '%1 %2')
    return (s:sub(1, 1):upper() .. s:sub(2))
  end
  local t = w:getTooltip() or ''
  t = t:match('^[^,(]+') or t
  return (t:gsub('^%s+', ''):gsub('%s+$', ''))
end

local rebuild, refreshSettings

-- one path for every way a tier can change: the settings window and the right-click menu on a row
local function favCount()
  local n = 0
  for _ in pairs(fav) do n = n + 1 end
  return n
end

local function setTier(id, newTier)
  if newTier == 'fav' and not fav[id] and favCount() >= MAX_FAVS then
    favFull = g_clock.millis()      -- the settings hint says so for a few seconds
    return
  end
  fav[id], off[id] = nil, nil
  if newTier == 'fav' then fav[id] = true elseif newTier == 'off' then off[id] = true end
  save()
  rebuild()
  if refreshSettings then refreshSettings() end
end

-- where a button belongs when it is not in one of our rows
local function defaultHome()
  local g = gb()
  local grid = g and g.contentsPanel and g.contentsPanel.buttons
  if grid then return grid end
  local tm = modules.client_topmenu.getTopMenu()
  return tm and tm:recursiveGetChildById('rightGameButtonsPanel') or nil
end

-- a reload can catch a button while it still sits in one of our rows; recording that row as its "home" would
-- park it into a widget we are about to destroy, which is what left the panel full of empty rows
local function homeFor(w)
  local q, depth = w:getParent(), 0
  while q and depth < 6 do
    if q == window or q == rowsPanel then return defaultHome() or w:getParent() end
    q = q:getParent(); depth = depth + 1
  end
  return w:getParent()
end

local function isOurs(w)
  for _, a in ipairs(adopted) do if a.btn == w then return true end end
  return false
end

local function collectNew()
  local found = {}
  local g = gb()
  local grid = g and g.contentsPanel and g.contentsPanel.buttons
  if grid then for _, w in ipairs(grid:getChildren()) do table.insert(found, w) end end
  local tm = modules.client_topmenu.getTopMenu()
  if tm then
    for _, pid in ipairs({ 'leftGameButtonsPanel', 'rightGameButtonsPanel' }) do
      local p = tm:recursiveGetChildById(pid)
      if p then for _, w in ipairs(p:getChildren()) do table.insert(found, w) end end
    end
  end
  local out = {}
  for _, w in ipairs(found) do
    if w:getId() and w:getId() ~= '' and w:getId() ~= 'topButtonsMenu' and not isOurs(w) then
      table.insert(out, w)
    end
  end
  return out
end

-- A button whose home panel no longer exists used to stay inside its row - and destroying the rows took the
-- button with it, which is how Talents, Tasks and friends disappeared over a few module reloads. Anything
-- without a home goes back to the client's own button panel instead.
local function fallbackHome()
  local tm = modules.client_topmenu and modules.client_topmenu.getTopMenu()
  local p = tm and tm:recursiveGetChildById('rightGameButtonsPanel')
  if p and not p:isDestroyed() then return p end
  local g = modules.game_buttons
  local grid = g and g.contentsPanel and g.contentsPanel.buttons
  if grid and not grid:isDestroyed() then return grid end
  return tm
end

local function parkAll()
  for _, a in ipairs(adopted) do
    local b = a.btn
    if b and not b:isDestroyed() then
      local home = (a.home and not a.home:isDestroyed()) and a.home or fallbackHome()
      if home and not home:isDestroyed() and b:getParent() ~= home then
        b:setParent(home)
        b:breakAnchors()
      end
    end
  end
  if rowsPanel then rowsPanel:destroyChildren() end
end

-- what the panel should look like right now: ids + tiers + the active filter. The 4s tick used to rebuild on
-- any row-count mismatch, which destroyed and recreated every row and snapped the right panel back to the top.
local function signature()
  local parts = {}
  for _, a in ipairs(adopted) do
    if a.btn and not a.btn:isDestroyed() then
      parts[#parts + 1] = a.btn:getId() .. ':' .. tierOf(a.btn:getId())
    end
  end
  table.sort(parts)
  return table.concat(parts, ',') .. '|' .. filter
end

rebuild = function()
  if not window or not rowsPanel then return end
  local bar = window:recursiveGetChildById('miniwindowScrollBar')
  local scroll = bar and bar:getValue() or nil
  parkAll()
  -- drop anything the client destroyed under us, and keep only the newest button per id: reloading a module
  -- leaves its old button behind, which showed up as a second row with the same name
  local alive, seenId = {}, {}
  for i = #adopted, 1, -1 do
    local a = adopted[i]
    local id = a.btn and not a.btn:isDestroyed() and a.btn:getId()
    if id and not seenId[id] then
      seenId[id] = true
      table.insert(alive, 1, a)
    elseif id then
      local home = fallbackHome()                    -- the stale twin goes home, never into a doomed row
      if home and not home:isDestroyed() then a.btn:setParent(home) a.btn:breakAnchors() a.btn:hide() end
    end
  end
  adopted = alive
  local listed, favCount = 0, 0
  for _, a in ipairs(adopted) do
    local btn = a.btn
    if btn and not btn:isDestroyed() then
      local tier = tierOf(btn:getId())
      local name = prettyName(btn)
      if tier == 'list' and filter ~= '' and not name:lower():find(filter, 1, true) then
        btn:setVisible(false)
      elseif tier == 'list' then
        local row = g_ui.createWidget('TopButtonsRow', rowsPanel)
        row.label:setText(name)
        btn:setParent(row)
        btn:breakAnchors()
        btn:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        btn:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
        btn:setMarginLeft(3)
        btn:setVisible(true)
        row.onHoverChange = function(w, hovered)
          w:setBackgroundColor(hovered and '#ffffff22' or '#00000000')
        end
        local cap, capId = btn, btn:getId()
        row.onMouseRelease = function(_, pos, mb)
          if mb == MouseLeftButton then
            if cap.onMouseRelease then cap.onMouseRelease(cap, cap:getPosition(), MouseLeftButton) end
            return true
          end
          if mb == MouseRightButton then
            local menu = g_ui.createWidget('PopupMenu')
            menu:setGameMenu(true)
            menu:addOption(tr('Add to favourites'), function() setTier(capId, 'fav') end)
            menu:addOption(tr('Hide'), function() setTier(capId, 'off') end)
            menu:display(pos)
            return true
          end
          return false
        end
        listed = listed + 1
      elseif tier == 'fav' then
        -- into OUR grid: the client's own button strip sits at the top of the screen in v3, which is the
        -- whole reason this panel exists
        if favsPanel then
          btn:setParent(favsPanel)
          btn:breakAnchors()
        end
        btn:setVisible(true)
        favCount = favCount + 1
      else
        btn:setVisible(false)
      end
    end
  end
  if favsWindow and not favsWindow:isDestroyed() then
    if favCount > 0 then
      -- favourites always stay on ONE row: the icons shrink to fit the panel instead of wrapping
      local avail = math.max(20, favsPanel:getWidth())
      local cell = math.max(14, math.min(28, math.floor((avail - 2 * (favCount - 1)) / favCount)))
      local layout = favsPanel:getLayout()
      if layout then
        -- fixing the column count is what actually forces a single row; flow would wrap on its own arithmetic
        pcall(function() layout:setCellSize({ width = cell, height = cell }) end)
        pcall(function() layout:setFlow(false) end)
        pcall(function() layout:setNumColumns(favCount) end)
      end
      for _, w in ipairs(favsPanel:getChildren()) do
        pcall(function() w:setSize({ width = cell, height = cell }) end)
      end
      favsWindow:setHeight(cell + 20)
      favsWindow:show()
    else
      favsWindow:hide()
    end
  end
  -- the client's own grid (v2 and older) is only up when something is favourited
  local g = gb()
  if g and g.buttonsWindow and not g.buttonsWindow:isDestroyed() then
    if favCount > 0 then
      if not g.buttonsWindow:isVisible() then g.buttonsWindow:show() end
    elseif g.buttonsWindow:isVisible() then
      g.buttonsWindow:hide()
    end
    if g.updateOrder then g.updateOrder() end
  end
  if listed == 0 then
    local row = g_ui.createWidget('TopButtonsRow', rowsPanel)
    row.label:setText(filter ~= '' and ("No button matches '" .. filter .. "'")
      or (#adopted == 0 and "No buttons found yet..." or "All buttons hidden - open the gear"))
    row.label:setColor('#9a9a9a')
    shownRows = 1
  else
    shownRows = listed
  end
  lastListed = listed
  lastSig = signature()
  fitHeight()
  if scroll and bar then bar:setValue(scroll) end
end

-- ---- settings: a real window that stays open, so many buttons can be re-tiered in one go ----
refreshSettings = function()
  if not settingsWin or settingsWin:isDestroyed() then return end
  local TIERS = { 'fav', 'list', 'off' }
  local cols, scroll = {}, {}
  for _, t in ipairs(TIERS) do
    cols[t] = settingsWin:recursiveGetChildById(t .. 'Col')
    local bar = settingsWin:recursiveGetChildById(t .. 'Scroll')
    scroll[t] = bar and bar:getValue() or 0
    if cols[t] then cols[t]:destroyChildren() end
  end

  local items = {}
  for _, a in ipairs(adopted) do if a.btn and not a.btn:isDestroyed() then table.insert(items, a.btn) end end
  table.sort(items, function(x, y) return prettyName(x):lower() < prettyName(y):lower() end)

  for _, btn in ipairs(items) do
    local id, tier = btn:getId(), tierOf(btn:getId())
    local row = g_ui.createWidget('TopButtonsDragRow', cols[tier])
    row.name:setText(prettyName(btn))
    row.btnId = id
    -- the real button moves in, so the row shows its actual icon; rebuild() puts it back in the list
    btn:setParent(row)
    btn:breakAnchors()
    btn:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    btn:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    btn:setMarginLeft(2)
    btn:setVisible(true)
    row.onHoverChange = function(w, hovered)
      w:setBackgroundColor(hovered and '#ffffff22' or '#00000000')
    end
    row.onDragEnter = function() return true end         -- dragging still works, the arrows are the sure way
    row.onDragLeave = function() return true end
    -- < and > move the entry one column over; the ends simply have nothing to move to
    local ORDER = { fav = 1, list = 2, off = 3 }
    local BY_INDEX = { 'fav', 'list', 'off' }
    local at = ORDER[tier]
    row.leftArrow:setEnabled(at > 1)
    row.rightArrow:setEnabled(at < 3)
    row.leftArrow.onClick = function() if at > 1 then setTier(id, BY_INDEX[at - 1]) end end
    row.rightArrow.onClick = function() if at < 3 then setTier(id, BY_INDEX[at + 1]) end end
  end

  for _, t in ipairs(TIERS) do
    local bar = settingsWin:recursiveGetChildById(t .. 'Scroll')
    if bar then bar:setValue(scroll[t]) end               -- a refresh used to throw the list back to the top
  end
end

local HINT = 'Use < and > to move a button between columns. Dragging works too.'

local function sweepHighlight()
  if not settingsWin or settingsWin:isDestroyed() then return end
  local hint = settingsWin:recursiveGetChildById('hint')
  if hint then
    local full = g_clock.millis() - favFull < 4000
    hint:setText(full and ('Favourites are limited to ' .. MAX_FAVS .. ' - move one out first.') or HINT)
    hint:setColor(full and '#ff8080' or '#b0b0b0')
  end
  for _, t in ipairs({ 'fav', 'list', 'off' }) do
    local col = settingsWin:recursiveGetChildById(t .. 'Col')
    if col then
      for _, row in ipairs(col:getChildren()) do
        row:setBackgroundColor(pointerOver(row) and '#ffffff22' or '#00000000')
      end
    end
  end
end

-- the settings rows hold the real buttons; closing has to give them back before the window is destroyed,
-- otherwise they are destroyed along with it
function closeSettings()
  if not settingsWin or settingsWin:isDestroyed() then settingsWin = nil return end
  local win = settingsWin
  settingsWin = nil
  if settingsSweep then removeEvent(settingsSweep) settingsSweep = nil end
  rebuild()
  win:destroy()
end

function showSettings()
  if settingsWin and not settingsWin:isDestroyed() then
    settingsWin:raise() settingsWin:focus() return
  end
  settingsWin = g_ui.createWidget('TopButtonsSettings', g_ui.getRootWidget())
  settingsWin:centerIn('parent')
  settingsWin.closeBtn.onClick = closeSettings
  settingsWin.onEscape = closeSettings
  settingsWin.resetBtn.onClick = function()
    fav, off = {}, {}
    save() rebuild() refreshSettings()
  end
  for _, t in ipairs({ 'fav', 'list', 'off' }) do
    local col = settingsWin:recursiveGetChildById(t .. 'Col')
    if col then
      col.onDrop = function(_, widget)
        if widget and widget.btnId then setTier(widget.btnId, t) return true end
        return false
      end
    end
  end
  refreshSettings()
  settingsSweep = cycleEvent(sweepHighlight, 150)
end

local function tick()
  if not window then return end
  if not window:isVisible() then window:show() end
  fitHeight()

  local fresh = collectNew()
  if #fresh > 0 then
    for _, w in ipairs(fresh) do table.insert(adopted, { btn = w, home = homeFor(w) }) end
    rebuild()
    refreshSettings()
    return
  end

  -- self-heal: if buttons died, or the row count no longer matches the tiers, rebuild. Without this a panel that
  -- came up half-built after a reload stayed broken forever, since rebuild only ran when NEW buttons appeared.
  local stale = false
  for _, a in ipairs(adopted) do
    if not a.btn or a.btn:isDestroyed() then stale = true end
  end
  if stale or signature() ~= lastSig then rebuild() end
  ensureOrder()
  if hijacked and searchBox and (not searchBox:isVisible() or not searchBox:isFocused() or collapsed()) then
    releaseKeyboard()
  end
end

function onMiniWindowClose()
  if window then scheduleEvent(function() if window then window:show() end end, 50) end
end

function toggleWindow() if window then window:show() end end

function init()
  load()
  window = g_ui.loadUI('top_buttons', modules.game_interface.getRightPanel())
  window:setup()
  window:show()
  -- a saved "minimized: true" is what brought the panel up as an empty box after a reload: setup() restores that
  -- state while we force the window visible, so the body renders collapsed. Always come up expanded.
  local closeBtn = window:recursiveGetChildById('closeButton')
  if closeBtn then closeBtn:hide() closeBtn:setWidth(0) end
  rowsPanel = window:recursiveGetChildById('rows')
  searchBox = window:recursiveGetChildById('search')
  if searchBox then
    -- the contents panel fills the window under a 22px title bar; make room for the pinned search box
    local contents = window:recursiveGetChildById('contentsPanel')
    local bar = window:recursiveGetChildById('miniwindowScrollBar')
    if contents then contents:setMarginTop(44) end
    if bar then bar:setMarginTop(44) end
    searchBox.onTextChange = function(_, text)
      filter = (text or ''):lower()
      rebuild()
    end
    searchBox.onMousePress = function(w)
      grabKeyboard(w)        -- a click alone only focuses inside the window, not up to the root
      return false
    end
    searchBox.onFocusChange = function(_, focused)
      if not focused then releaseKeyboard() end
    end
    local EDITING = { [KeyBackspace] = true, [KeyDelete] = true, [KeyLeft] = true, [KeyRight] = true,
                      [KeyHome] = true, [KeyEnd] = true }
    searchBox.onKeyPress = function(_, keyCode)
      if keyCode == KeyEscape then
        searchBox:setText('')
        releaseKeyboard()
        return true
      end
      if EDITING[keyCode] then return false end
      return hijacked        -- swallow the rest so game hotkeys stay quiet while typing
    end
  end
  -- opening the panel starts a fresh search: an old query left in the box hides half the list
  connect(window, {
    onMaximize = function()
      if not searchBox then return end
      searchBox:setText('')
      filter = ''
    end,
    onMinimize = function() releaseKeyboard() end,
  })
  -- Favourites sit in their OWN window ABOVE this one: bare icons inside the list panel were harder to find
  -- than the labelled rows, and the point of a favourite is to stay in view when the list is minimised.
  local panel = modules.game_interface.getRightPanel()
  favsWindow = g_ui.createWidget('TopFavsWindow', panel)
  favsWindow:setup()
  local fc = favsWindow:recursiveGetChildById('closeButton')
  if fc then fc:hide() fc:setWidth(0) end
  favsPanel = favsWindow:recursiveGetChildById('favs')
  -- no scrollbar on the favourites: with a hard cap of MAX_FAVS everything always fits
  local favBar = favsWindow:recursiveGetChildById('miniwindowScrollBar')
  if favBar then favBar:hide() favBar:setWidth(0) end
  local favContents = favsWindow:recursiveGetChildById('contentsPanel')
  if favContents then favContents:setMarginRight(3) end
  ensureOrder()   -- the focus path is opened only while the box is in use, see syncGrab()
  favsWindow:hide()
  settingsBtn = window:recursiveGetChildById('settingsButton')
  if settingsBtn then
    settingsBtn.onClick = showSettings
    local lock = window:recursiveGetChildById('lockButton')
    if lock then                                    -- the title bar already has close/minimize/lock
      settingsBtn:breakAnchors()
      settingsBtn:addAnchor(AnchorRight, 'lockButton', AnchorLeft)
      settingsBtn:addAnchor(AnchorVerticalCenter, 'lockButton', AnchorVerticalCenter)
      settingsBtn:setMarginRight(5)
    end
  end
  connect(g_game, { onGameStart = tick })
  grabEvent = cycleEvent(syncGrab, 100)
  -- temporary: record who holds the keyboard, so a lost Tab can be traced to the widget that took focus
  focusEvent = cycleEvent(function()
    local f = g_ui.getRootWidget():getFocusedChild()
    local chain = {}
    while f do chain[#chain + 1] = f:getId() or '?' f = f:getFocusedChild() end
    local line = table.concat(chain, '>')
    if line ~= lastFocusLine then
      lastFocusLine = line
      table.insert(focusTrail, os.date('%H:%M:%S') .. ' ' .. line)
      while #focusTrail > 40 do table.remove(focusTrail, 1) end
      g_resources.writeFileContents('/focus_trail.txt', table.concat(focusTrail, '\n') .. '\n')
    end
  end, 400)
  scheduleEvent(tick, 600)
  scheduleEvent(tick, 2000)
  tickEvent = cycleEvent(tick, 4000)
end

function grabState() return hijacked end

function terminate()
  releaseKeyboard()
  if grabEvent then removeEvent(grabEvent) grabEvent = nil end
  if focusEvent then removeEvent(focusEvent) focusEvent = nil end
  for _, w in ipairs(madeFocusable) do
    if w and not w:isDestroyed() then w:setFocusable(false) end
  end
  madeFocusable = {}
  disconnect(g_game, { onGameStart = tick })
  removeEvent(tickEvent)
  -- give every button back BEFORE any of our windows is destroyed: favourites live inside the favourites
  -- window, so destroying it first took them with it (that is where Talents, Tasks and the rest went)
  closeSettings()
  parkAll()
  if favsWindow and not favsWindow:isDestroyed() then favsWindow:destroy() favsWindow = nil end
  for _, a in ipairs(adopted) do
    if a.btn and not a.btn:isDestroyed() then a.btn:setVisible(true) end
  end
  adopted = {}
  local g = gb()
  if g and g.buttonsWindow and not g.buttonsWindow:isDestroyed() then
    g.buttonsWindow:show()
    if g.updateOrder then g.updateOrder() end
  end
  if window then window:destroy() window = nil end
end
