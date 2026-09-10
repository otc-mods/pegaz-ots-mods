-- Better top buttons: a MiniWindow in the right panel listing game buttons as [real icon] + name. Every button
-- has one of three tiers:
--   fav  - stays an icon in the client's old Buttons grid (quick access, shown above this panel)
--   list - a row in this panel (the default)
--   off  - not shown anywhere
-- Rows hold the ACTUAL button widget, so the real icon draws itself and clicks work natively. Buttons are handed
-- back to their home panel on unload, so uninstalling restores stock behaviour.
local ROW_H, BASE_H = 22, 26

local window, rowsPanel, settingsBtn, settingsWin
local adopted = {}          -- { { btn = widget, home = original parent } }
local fav, off = {}, {}     -- id -> true
local tickEvent
local lastListed, shownRows = -1, -1

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
  window:setHeight(BASE_H + math.max(shownRows, 0) * ROW_H)
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
    for _, id in ipairs(idsFrom(node.fav)) do fav[id] = true end
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

-- park every adopted button back on its home panel, then it is safe to destroy the rows that held them
local function parkAll()
  for _, a in ipairs(adopted) do
    local b = a.btn
    if b and not b:isDestroyed() and a.home and not a.home:isDestroyed() and b:getParent() ~= a.home then
      b:setParent(a.home)
      b:breakAnchors()
    end
  end
  if rowsPanel then rowsPanel:destroyChildren() end
end

local rebuild
rebuild = function()
  if not window or not rowsPanel then return end
  parkAll()
  -- drop anything the client destroyed under us
  local alive = {}
  for _, a in ipairs(adopted) do
    if a.btn and not a.btn:isDestroyed() then table.insert(alive, a) end
  end
  adopted = alive
  local listed, favCount = 0, 0
  for _, a in ipairs(adopted) do
    local btn = a.btn
    if btn and not btn:isDestroyed() then
      local tier = tierOf(btn:getId())
      if tier == 'list' then
        local row = g_ui.createWidget('TopButtonsRow', rowsPanel)
        row.label:setText(prettyName(btn))
        btn:setParent(row)
        btn:breakAnchors()
        btn:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        btn:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
        btn:setMarginLeft(3)
        btn:setVisible(true)
        row.onHoverChange = function(w, hovered)
          w:setBackgroundColor(hovered and '#ffffff22' or '#00000000')
        end
        local cap = btn
        row.onMouseRelease = function(_, pos, mb)
          if mb == MouseLeftButton then
            if cap.onMouseRelease then cap.onMouseRelease(cap, cap:getPosition(), MouseLeftButton) end
            return true
          end
          return false
        end
        listed = listed + 1
      elseif tier == 'fav' then
        btn:setVisible(true)
        favCount = favCount + 1
      else
        btn:setVisible(false)
      end
    end
  end
  -- the old grid is only up when something is favourited
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
    row.label:setText(#adopted == 0 and "No buttons found yet..." or "All buttons hidden - open the gear")
    row.label:setColor('#9a9a9a')
    shownRows = 1
  else
    shownRows = listed
  end
  lastListed = listed
  fitHeight()
end

-- ---- settings: a real window that stays open, so many buttons can be re-tiered in one go ----
local function refreshSettings()
  if not settingsWin or settingsWin:isDestroyed() then return end
  local list = settingsWin:recursiveGetChildById('list')
  list:destroyChildren()
  local items = {}
  for _, a in ipairs(adopted) do if a.btn and not a.btn:isDestroyed() then table.insert(items, a.btn) end end
  table.sort(items, function(x, y) return prettyName(x):lower() < prettyName(y):lower() end)
  for _, btn in ipairs(items) do
    local id = btn:getId()
    local row = g_ui.createWidget('TopButtonsSetRow', list)
    row.name:setText(prettyName(btn))
    local tier = tierOf(id)
    local map = { fav = row.favBtn, list = row.listBtn, off = row.offBtn }
    for name, b in pairs(map) do
      b:setColor(name == tier and '#55ff55' or '#c0c0c0')
    end
    local function set(newTier)
      fav[id], off[id] = nil, nil
      if newTier == 'fav' then fav[id] = true elseif newTier == 'off' then off[id] = true end
      save()
      rebuild()
      refreshSettings()      -- window stays open; only the rows repaint
    end
    row.favBtn.onClick  = function() set('fav') end
    row.listBtn.onClick = function() set('list') end
    row.offBtn.onClick  = function() set('off') end
  end
end

function showSettings()
  if settingsWin and not settingsWin:isDestroyed() then
    settingsWin:raise() settingsWin:focus() return
  end
  settingsWin = g_ui.createWidget('TopButtonsSettings', g_ui.getRootWidget())
  settingsWin:centerIn('parent')
  settingsWin.closeBtn.onClick = function() settingsWin:destroy() settingsWin = nil end
  settingsWin.resetBtn.onClick = function()
    fav, off = {}, {}
    save() rebuild() refreshSettings()
  end
  refreshSettings()
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
  local stale, expected = false, 0
  for _, a in ipairs(adopted) do
    if not a.btn or a.btn:isDestroyed() then
      stale = true
    elseif tierOf(a.btn:getId()) == 'list' then
      expected = expected + 1
    end
  end
  if stale or expected ~= lastListed or (rowsPanel and rowsPanel:getChildCount() ~= shownRows) then rebuild() end
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
  settingsBtn = window:recursiveGetChildById('settingsButton')
  if settingsBtn then settingsBtn.onClick = showSettings end
  connect(g_game, { onGameStart = tick })
  scheduleEvent(tick, 600)
  scheduleEvent(tick, 2000)
  tickEvent = cycleEvent(tick, 4000)
end

function terminate()
  disconnect(g_game, { onGameStart = tick })
  removeEvent(tickEvent)
  if settingsWin and not settingsWin:isDestroyed() then settingsWin:destroy() end
  settingsWin = nil
  parkAll()
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
