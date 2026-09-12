-- Better chat: a split view beside the normal console. The coloured [!] buttons on the right rail are filter tabs:
-- each picks message sources, channel names, include/exclude patterns (plain or regex), flash and sound, and keeps
-- its own history. Everything lives inside the console panel, so the stock chat keeps its tabs and input line; the
-- split is resizable by dragging the bar between the two views. Clicking the active [!] collapses the split view.

local SETTINGS_KEY = 'betterChat'
local SEED_VERSION = 1
local MIN_SPLIT, MIN_CONSOLE = 120, 200
local SOUND_EVERY_MS = 3000

COLORS = { -- [!] button background / text
  red    = { bg = '#b32424', fg = '#ffffff' },
  yellow = { bg = '#d8c22e', fg = '#222222' },
  white  = { bg = '#e6e6e6', fg = '#222222' },
  blue   = { bg = '#2e7bd8', fg = '#ffffff' },
  green  = { bg = '#2e9e4a', fg = '#ffffff' },
  orange = { bg = '#e08a2e', fg = '#222222' },
}
COLOR_ORDER = { 'red', 'yellow', 'white', 'blue', 'green', 'orange' }
local TEXT = { yellow = '#FFFF00', white = '#FFFFFF', red = '#F55E5E', orange = '#F6A731', green = '#00EB00', lightblue = '#5FF7F7', blue = '#9F9DFD' }

SOURCES = {
  { id = 'local',   text = 'Local' },
  { id = 'private', text = 'Private' },
  { id = 'channel', text = 'Channels' },
  { id = 'npc',     text = 'NPCs' },
  { id = 'status',  text = 'Server log' },
  { id = 'loot',    text = 'Loot' },
  { id = 'red',     text = 'Red texts' },
  { id = 'game',    text = 'Game msgs' },
  { id = 'monster', text = 'Monsters' },
}

local cfg                    -- { width (fraction), collapsed, active (tab id), seedVersion, tabs = {...} }
local consolePanel, contentPanel, panel, splitter, rail
local bangs = {}             -- tab id -> [!] button
local unread = {}            -- tab id -> count since last viewed
local history = {}           -- tab id -> { {text, color, name, source}, ... }
-- switching tabs re-renders every kept line, so a huge history is paid for on every click: 2000 lines lag
local MAX_KEEP = 500
local function clampKeep(v) return math.max(20, math.min(MAX_KEEP, tonumber(v) or 200)) end
local lastSound = {}
local flashEvent, splitEvent, flashOn = nil, false
local settingsWindow
local tagUntil = 0           -- while set, rows are prefixed with their source, to see where a message comes from
local pendingJoin            -- { names = {lower -> name}, t } while we wait for the channel list to join channels
local channelsEvent
local selectTab, openSettings, rebuildRail, renderActive

local function truthy(v) return v == true or v == 'true' or v == 1 end

-- settings arrays come back with string keys
local function toArray(t)
  if type(t) ~= 'table' then return {} end
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  local out = {}
  for _, k in ipairs(keys) do table.insert(out, t[k]) end
  return out
end

local function newTab(o)
  o.id = o.id or (tostring(os.time()) .. '_' .. math.random(100, 999))
  o.name = o.name or 'Tab'
  o.color = o.color or 'white'
  o.sources = o.sources or {}
  o.channels = o.channels or ''
  o.include = o.include or ''
  o.exclude = o.exclude or ''
  o.keep = clampKeep(o.keep)
  if o.flash == nil then o.flash = true end
  if o.skipOpen == nil then o.skipOpen = true end -- private source: skip people whose chat tab is already open
  o.sound = o.sound or false
  o.regex = o.regex or false
  return o
end

local function seed()
  if #cfg.tabs == 0 then
    cfg.tabs = {
      newTab{ id = 'alerts',  name = 'Alerts',         color = 'red',    sources = { red = true } },
      newTab{ id = 'trade',   name = 'Trade',          color = 'yellow', sources = { channel = true }, channels = 'Trade, Advertising' },
      newTab{ id = 'server',  name = 'Raids & server', color = 'white',  sources = { game = true, red = true } },
      newTab{ id = 'private', name = 'Private',        color = 'blue',   sources = { private = true } },
    }
    cfg.active = 'trade'
  end
  cfg.seedVersion = SEED_VERSION
end

local function load()
  local node = g_settings.getNode(SETTINGS_KEY)
  cfg = { width = 0.33, collapsed = false, active = nil, seedVersion = 0, tabs = {}, keepChannels = true }
  if type(node) == 'table' then
    cfg.width = tonumber(node.width) or cfg.width
    if node.keepChannels ~= nil then cfg.keepChannels = truthy(node.keepChannels) end
    cfg.collapsed = truthy(node.collapsed)
    cfg.active = node.active
    cfg.seedVersion = tonumber(node.seedVersion) or 0
    for _, t in ipairs(toArray(node.tabs)) do
      if type(t) == 'table' and t.id then
        local src = {}
        if type(t.sources) == 'table' then for k, v in pairs(t.sources) do if truthy(v) then src[k] = true end end end
        t.sources = src
        t.keep = clampKeep(t.keep)
        t.flash, t.sound, t.regex = truthy(t.flash), truthy(t.sound), truthy(t.regex)
        if t.skipOpen ~= nil then t.skipOpen = truthy(t.skipOpen) end
        table.insert(cfg.tabs, newTab(t))
      end
    end
  end
  if cfg.seedVersion < SEED_VERSION then seed() end
end

local function save() g_settings.setNode(SETTINGS_KEY, cfg) end

local function activeTab()
  for _, t in ipairs(cfg.tabs) do if t.id == cfg.active then return t end end
  return cfg.tabs[1]
end

-- matching -----------------------------------------------------------------------------------------

local function patterns(s)
  local out = {}
  for line in tostring(s or ''):gmatch('[^\r\n]+') do
    line = line:trim()
    if #line > 0 then table.insert(out, line) end
  end
  return out
end

local function matchesAny(tab, text, list)
  local lower = text:lower()
  for _, pat in ipairs(list) do
    if truthy(tab.regex) then
      -- the client's regex engine has no inline (?i): try as typed, then both sides lower-cased
      local ok, res = pcall(regexMatch, text, pat)
      if ok and type(res) == 'table' and #res > 0 then return true end
      ok, res = pcall(regexMatch, lower, pat:lower())
      if ok and type(res) == 'table' and #res > 0 then return true end
    elseif lower:find(pat:lower(), 1, true) then
      return true
    end
  end
  return false
end

local function tabMatches(tab, source, text, channelName, name)
  if not tab.sources[source] then return false end
  -- a private chat tab for this person is open: the message is in plain sight already (checked before the
  -- console handles the message, so a tab the console opens for this very line does not count)
  if source == 'private' and truthy(tab.skipOpen) and name and modules.game_console.getTab(name) then return false end
  if source == 'channel' then
    local wanted = patterns((tab.channels or ''):gsub(',', '\n'))
    if #wanted > 0 then
      local ok = false
      for _, w in ipairs(wanted) do
        if channelName and channelName:lower() == w:lower() then ok = true break end
      end
      if not ok then return false end
    end
  end
  local inc = patterns(tab.include)
  if #inc > 0 and not matchesAny(tab, text, inc) then return false end
  local exc = patterns(tab.exclude)
  if #exc > 0 and matchesAny(tab, text, exc) then return false end
  return true
end

-- rendering ----------------------------------------------------------------------------------------

-- text the user dragged over, across all rows of the tab (rows are selectable text edits like the console's)
local function selectionText()
  if not panel then return nil end
  local parts = {}
  for _, row in ipairs(panel.buffer:getChildren()) do
    local sel = row.getSelection and row:getSelection()
    if sel and #sel > 0 then table.insert(parts, sel) end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, '\n')
end

local function allText()
  local tab = activeTab()
  local parts = {}
  for _, m in ipairs((tab and history[tab.id]) or {}) do table.insert(parts, m.text) end
  return table.concat(parts, '\n')
end

local function clearSelection()
  if not panel then return end
  for _, row in ipairs(panel.buffer:getChildren()) do
    if row.setSelection then row:setSelection(0, 0) end
  end
end

local function selectAllRows()
  if not panel then return end
  for _, row in ipairs(panel.buffer:getChildren()) do
    if row.setSelection then row:setSelection(0, #row:getText()) end
  end
end

local function addRow(msg)
  local row = g_ui.createWidget('BetterChatRow', panel.buffer)
  row:setText(msg.text)
  row:setColor(msg.color)
  if msg.source == 'private' then row:setTooltip('Click: open chat with ' .. (msg.name or '?')) end
  row.onMouseRelease = function(_, pos, button)
    local me = g_game.getCharacterName()
    if button == MouseRightButton then
      local console = modules.game_console
      local menu = g_ui.createWidget('PopupMenu')
      menu:setGameMenu(true)
      if msg.name and #msg.name > 0 and msg.name ~= me then
        menu:addOption('Open chat with ' .. msg.name, function() console.addPrivateChannel(msg.name) end)
        menu:addOption('Exiva ' .. msg.name, function() g_game.talk('exiva "' .. msg.name .. '"') end)
        local me2 = g_game.getLocalPlayer()
        if me2 and not me2:hasVip(msg.name) then
          menu:addOption('Add to VIP list', function() g_game.addVip(msg.name) end)
        end
        if console.isIgnored and console.isIgnored(msg.name) then
          menu:addOption('Unignore ' .. msg.name, function() console.removeIgnoredPlayer(msg.name) end)
        elseif console.addIgnoredPlayer then
          menu:addOption('Ignore ' .. msg.name, function() console.addIgnoredPlayer(msg.name) end)
        end
        menu:addSeparator()
        menu:addOption('Copy name', function() g_window.setClipboardText(msg.name) end)
      end
      local sel = selectionText()
      if sel then menu:addOption('Copy selection', function() g_window.setClipboardText(sel) end) end
      menu:addOption('Copy message', function() g_window.setClipboardText(msg.text) end)
    menu:addOption('Copy whole tab', function() g_window.setClipboardText(allText()) end)
      menu:addSeparator()
      menu:addOption('Select all', selectAllRows)
      if sel then menu:addOption('Clear selection', clearSelection) end
      menu:display(pos)
      return true
    elseif button == MouseLeftButton and msg.source == 'private' and msg.name and msg.name ~= me then
      modules.game_console.addPrivateChannel(msg.name)
      return true
    end
    return false
  end
end

renderActive = function()
  if not panel then return end
  panel.buffer:destroyChildren()
  local tab = activeTab()
  if not tab then panel.header.name:setText('no filter tabs - press + on the right') return end
  panel.header.name:setText(tab.name)
  for _, msg in ipairs(history[tab.id] or {}) do addRow(msg) end
end

local function refreshBangs()
  for _, tab in ipairs(cfg.tabs) do
    local b = bangs[tab.id]
    if b then
      local active = tab.id == cfg.active and not cfg.collapsed
      local n = unread[tab.id] or 0
      local flashing = n > 0 and truthy(tab.flash) and not active
      b:setBorderColor((active or (flashing and flashOn)) and '#ffffff' or '#000000')
      b:setBorderWidth((active or flashing) and 2 or 1)
      b:setOpacity((active or n > 0) and 1 or 0.65)
      b.badge:setText(n > 99 and '99+' or tostring(n))
      b.badge:setVisible(n > 0)
    end
  end
end

local function tick()
  flashOn = not flashOn
  refreshBangs()
end

-- the console is often only ~100 px tall: shrink the [!] buttons so every tab fits inside the rail
-- (children outside the rail's rect are not clickable)
local function fitRail()
  if not rail then return end
  local n = #cfg.tabs
  if n == 0 then return end
  local avail = rail:getHeight() - 2 * (n - 1)
  local h = math.max(10, math.min(20, math.floor(avail / n)))
  for _, tab in ipairs(cfg.tabs) do
    local b = bangs[tab.id]
    if b then b:setHeight(h) end
  end
end

local function applyLayout()
  if not consolePanel or not panel then return end
  local total = consolePanel:getWidth()
  if total <= 0 then return end
  local w = math.floor(total * (cfg.width or 0.33))
  w = math.max(MIN_SPLIT, math.min(w, total - MIN_CONSOLE))
  panel:setWidth(w)
  panel:setVisible(not cfg.collapsed)
  splitter:setVisible(not cfg.collapsed)
  contentPanel:addAnchor(AnchorRight, cfg.collapsed and 'betterChatRail' or 'betterChatSplitter', AnchorLeft)
  fitRail()
end

local function playSound(tab)
  if not g_sounds then return end
  local t = g_clock.millis()
  if (lastSound[tab.id] or 0) + SOUND_EVERY_MS > t then return end
  lastSound[tab.id] = t
  local ch = g_sounds.getChannel(SoundChannels.Effect)
  if ch then
    ch:setEnabled(true)
    ch:play('/sounds/alarm.ogg', 0, 1.0)
  end
end

local function deliver(source, text, color, name, channelName)
  if not cfg then return end
  local full = text
  if modules.client_options.getOption('showTimestampsInConsole') then full = os.date('%H:%M') .. ' ' .. text end
  if g_clock.millis() < tagUntil then full = '[' .. source .. '] ' .. full end
  local changed = false
  for _, tab in ipairs(cfg.tabs) do
    if tabMatches(tab, source, text, channelName, name) then
      local msg = { text = full, color = color, name = name, source = source }
      local h = history[tab.id] or {}
      history[tab.id] = h
      table.insert(h, msg)
      while #h > (tab.keep or 200) do table.remove(h, 1) end
      if tab.id == cfg.active and not cfg.collapsed and panel then
        addRow(msg)
        while panel.buffer:getChildCount() > (tab.keep or 200) do panel.buffer:getFirstChild():destroy() end
      else
        unread[tab.id] = (unread[tab.id] or 0) + 1
        changed = true
      end
      if truthy(tab.sound) then playSound(tab) end
    end
  end
  if changed then refreshBangs() end
end

-- keep channels open: the server only sends channel messages for channels you joined, and they drop on
-- relog. Every tab's "Only channels" names are (re)joined on login and once a minute, without the channel window.
local function wantedChannelNames()
  local set = {}
  for _, tab in ipairs(cfg.tabs) do
    if tab.sources.channel then
      for _, n in ipairs(patterns((tab.channels or ''):gsub(',', '\n'))) do set[n:lower()] = n end
    end
  end
  return set
end

local function openChannelNames()
  local set = {}
  local ch = modules.game_console.channels
  if type(ch) == 'table' then
    for _, name in pairs(ch) do if type(name) == 'string' then set[name:lower()] = true end end
  end
  return set
end

local function ensureChannels()
  if not cfg or not truthy(cfg.keepChannels) or not g_game.isOnline() then return end
  local wanted, open, missing = wantedChannelNames(), openChannelNames(), {}
  for lower, name in pairs(wanted) do if not open[lower] then missing[lower] = name end end
  if next(missing) == nil then return end
  pendingJoin = { names = missing, t = g_clock.millis() }
  g_game.requestChannels()
end

local function onChannelList(list)
  if not pendingJoin or g_clock.millis() - pendingJoin.t > 3000 then return end -- a manual Ctrl+O: not ours
  local names = pendingJoin.names
  pendingJoin = nil
  for _, v in pairs(list) do
    local id, name = v[1], v[2]
    if type(name) == 'string' and names[name:lower()] then g_game.joinChannel(id) end
  end
  local function closeWindow()
    local w = modules.game_console.channelsWindow
    if w then w:destroy() end
  end
  closeWindow()
  scheduleEvent(closeWindow, 50)
end

local function onGameStart()
  applyLayout()
  scheduleEvent(ensureChannels, 3000)
end

-- message sources ------------------------------------------------------------------------------------

local function modeSet(names)
  local s = {}
  for _, n in ipairs(names) do if MessageModes[n] then s[MessageModes[n]] = true end end
  return s
end
local RED_MODES = modeSet{ 'Warning', 'Red', 'GamemasterBroadcast', 'Report' }
local GAME_MODES = modeSet{ 'Game', 'Login', 'TutorialHint', 'BeyondLast', 'PartyManagement', 'Guild', 'TradeNpc', 'Blue' }
local STATUS_MODES = modeSet{ 'Status', 'DamageDealed', 'DamageReceived', 'Heal', 'Exp', 'Failure', 'Look', 'HotkeyUse', 'Party' }
local GREEN_MODES = modeSet{ 'Look', 'HotkeyUse', 'Party' }
local LOOT_MODES = modeSet{ 'Loot' }
local MONSTER_MODES = modeSet{ 'MonsterSay', 'MonsterYell', 'BarkLow', 'BarkLoud' }

local function onTalk(name, level, mode, text, channelId, pos)
  if type(text) ~= 'string' then return end
  local M = MessageModes
  local composed = text
  if name and #name > 0 then
    if modules.client_options.getOption('showLevelsInConsole') and level and level > 0 then
      composed = name .. ' [' .. level .. ']: ' .. text
    else
      composed = name .. ': ' .. text
    end
  end
  if mode == M.Say or mode == M.Whisper or mode == M.Yell then
    deliver('local', composed, TEXT.yellow, name)
  elseif mode == M.PrivateFrom then
    deliver('private', composed, TEXT.lightblue, name)
  elseif mode == M.GamemasterPrivateFrom then
    deliver('private', composed, TEXT.red, name)
  elseif mode == M.Channel or mode == M.ChannelManagement or mode == M.ChannelHighlight or mode == M.GamemasterChannel then
    local channels = modules.game_console.channels
    local chName = (type(channels) == 'table' and channels[channelId]) or ('#' .. tostring(channelId))
    local color = TEXT.yellow
    if mode == M.ChannelManagement then color = TEXT.white
    elseif mode == M.ChannelHighlight then color = TEXT.orange
    elseif mode == M.GamemasterChannel then color = TEXT.red end
    deliver('channel', composed, color, name, chName)
  elseif mode == M.NpcFrom or mode == M.NpcFromStartBlock then
    deliver('npc', composed, TEXT.lightblue, name)
  elseif mode == M.GamemasterBroadcast then
    deliver('red', composed, TEXT.red, name)
  elseif mode == M.MonsterSay or mode == M.MonsterYell then
    deliver('monster', composed, TEXT.orange, name)
  end
end

local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  if RED_MODES[mode] then deliver('red', text, TEXT.red)
  elseif GAME_MODES[mode] then deliver('game', text, mode == MessageModes.Blue and TEXT.blue or TEXT.white)
  elseif LOOT_MODES[mode] then deliver('loot', text, TEXT.green)
  elseif STATUS_MODES[mode] then deliver('status', text, GREEN_MODES[mode] and TEXT.green or TEXT.white)
  elseif MONSTER_MODES[mode] then deliver('monster', text, TEXT.orange)
  end
end

-- tabs / rail ----------------------------------------------------------------------------------------

selectTab = function(id)
  if cfg.active == id and not cfg.collapsed then
    cfg.collapsed = true
  else
    cfg.active = id
    cfg.collapsed = false
  end
  unread[id] = 0
  applyLayout()
  renderActive()
  refreshBangs()
  save()
end

rebuildRail = function()
  rail:destroyChildren()
  bangs = {}
  for _, tab in ipairs(cfg.tabs) do
    local b = g_ui.createWidget('BetterChatBang', rail)
    local c = COLORS[tab.color] or COLORS.white
    b:setBackgroundColor(c.bg)
    b:setColor(c.fg)
    b:setTooltip(tab.name .. ' - click: show / hide, right click: settings')
    local id = tab.id
    b.onClick = function() selectTab(id) end
    b.onMouseRelease = function(_, pos, button)
      if button == MouseRightButton then openSettings(tab, false) return true end
      return false
    end
    bangs[tab.id] = b
  end
  fitRail()
  refreshBangs()
end

openSettings = function(tab, isNew)
  if settingsWindow then settingsWindow:destroy() end
  local w = g_ui.createWidget('BetterChatSettings', g_ui.getRootWidget())
  settingsWindow = w
  local c = w.content
  c.nameRow.text:setText('Name')
  c.nameRow.value:setText(tab.name or '')
  c.colorRow.text:setText('Colour')
  for i, k in ipairs(COLOR_ORDER) do
    c.colorRow.value:addOption(k, k)
    if k == tab.color then c.colorRow.value:setCurrentIndex(i) end
  end
  c.sourcesRow.text:setText('Listen to')
  local boxes = {}
  for _, s in ipairs(SOURCES) do
    local cb = g_ui.createWidget('CheckBox', c.sourcesRow.value)
    cb:setText(s.text)
    cb:setChecked(tab.sources[s.id] == true)
    boxes[s.id] = cb
  end
  c.channelsRow.text:setText('Only channels')
  c.channelsRow.text:setTooltip('For the Channels source: comma separated names, e.g. Trade, Advertising. Empty = every channel.')
  c.channelsRow.value:setText(tab.channels or '')
  c.includeRow.text:setText('Show matching')
  c.includeRow.text:setTooltip('One pattern per line, case-insensitive. Empty = everything from the sources.')
  c.includeRow.value:setText(tab.include or '')
  c.excludeRow.text:setText('Hide matching')
  c.excludeRow.value:setText(tab.exclude or '')
  c.flagsRow.text:setText('Options')
  local regex = g_ui.createWidget('CheckBox', c.flagsRow.value)
  regex:setText('regex patterns')
  regex:setChecked(truthy(tab.regex))
  local flash = g_ui.createWidget('CheckBox', c.flagsRow.value)
  flash:setText('flash [!] when unread')
  flash:setChecked(truthy(tab.flash))
  local sound = g_ui.createWidget('CheckBox', c.flagsRow.value)
  sound:setText('sound')
  sound:setChecked(truthy(tab.sound))
  local skip = g_ui.createWidget('CheckBox', c.flagsRow.value)
  skip:setText('skip open priv chats')
  skip:setTooltip('Private source: do not show messages from people whose chat tab is already open in the console')
  skip:setChecked(truthy(tab.skipOpen))
  c.keepRow.text:setText('Keep last')            -- the row is narrow; the limit lives in the tooltip
  c.keepRow:setTooltip('Lines kept per tab: 20 to ' .. MAX_KEEP .. ' (more than that makes tab switching lag)')
  c.keepRow.value:setText(tostring(tab.keep or 200))

  w.deleteButton:setVisible(not isNew)
  w.deleteButton.onClick = function()
    for i, t in ipairs(cfg.tabs) do if t == tab then table.remove(cfg.tabs, i) break end end
    history[tab.id] = nil
    unread[tab.id] = nil
    if cfg.active == tab.id then cfg.active = cfg.tabs[1] and cfg.tabs[1].id end
    save()
    rebuildRail()
    renderActive()
    w:destroy()
  end
  w.cancelButton.onClick = function() w:destroy() end
  w.saveButton.onClick = function()
    tab.name = c.nameRow.value:getText()
    if #tab.name == 0 then tab.name = 'Tab' end
    local opt = c.colorRow.value:getCurrentOption()
    tab.color = (opt and opt.data) or 'white'
    tab.sources = {}
    for id, cb in pairs(boxes) do if cb:isChecked() then tab.sources[id] = true end end
    tab.channels = c.channelsRow.value:getText()
    tab.include = c.includeRow.value:getText()
    tab.exclude = c.excludeRow.value:getText()
    tab.regex, tab.flash, tab.sound, tab.skipOpen = regex:isChecked(), flash:isChecked(), sound:isChecked(), skip:isChecked()
    tab.keep = clampKeep(c.keepRow.value:getText())
    if isNew then
      table.insert(cfg.tabs, tab)
      cfg.active = tab.id
      cfg.collapsed = false
    end
    save()
    rebuildRail()
    applyLayout()
    renderActive()
    scheduleEvent(ensureChannels, 300)
    w:destroy()
  end
  w.onDestroy = function() settingsWindow = nil end
end

-- lifecycle -------------------------------------------------------------------------------------------

-- same vertical span as consoleContentPanel, but anchored to ITS neighbours: the layout engine calls any
-- dependency between two widgets a cycle, even across axes, and the content panel hangs off our splitter
local function anchorLikeContent(widget)
  if consolePanel:getChildById('ignoreButton') then
    widget:addAnchor(AnchorTop, 'ignoreButton', AnchorBottom)
    widget:setMarginTop(4)
  else
    widget:addAnchor(AnchorTop, 'parent', AnchorTop)
    widget:setMarginTop(32)
  end
  if consolePanel:getChildById('consoleTextEdit') then
    widget:addAnchor(AnchorBottom, 'consoleTextEdit', AnchorTop)
    widget:setMarginBottom(4)
  else
    widget:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    widget:setMarginBottom(30)
  end
end

function init()
  load()
  g_ui.importStyle('better_chat')
  consolePanel = modules.game_interface.getBottomPanel():getChildById('consolePanel')
  if not consolePanel then print('better chat: console panel not found, module idle') return end
  contentPanel = consolePanel:getChildById('consoleContentPanel')

  rail = g_ui.createWidget('BetterChatRail', consolePanel)
  rail:setId('betterChatRail')
  anchorLikeContent(rail)
  rail:addAnchor(AnchorRight, 'parent', AnchorRight)
  rail:setMarginRight(6)
  rail:setMarginTop(rail:getMarginTop() + 20) -- start level with the message areas, below the split view header
  rail.onGeometryChange = function() fitRail() end

  panel = g_ui.createWidget('BetterChatPanel', consolePanel)
  panel:setId('betterChatPanel')
  anchorLikeContent(panel)
  panel:addAnchor(AnchorRight, 'betterChatRail', AnchorLeft)
  panel:setMarginRight(4)
  panel.header.menu.onClick = function()
    local tab = activeTab()
    local menu = g_ui.createWidget('PopupMenu')
    menu:setGameMenu(true)
    if tab then
      menu:addOption('Settings of "' .. tab.name .. '"...', function() openSettings(tab, false) end)
      menu:addOption('Clear "' .. tab.name .. '"', function() history[tab.id] = {} renderActive() end)
    menu:addOption('Copy whole tab', function() g_window.setClipboardText(allText()) end)
      menu:addSeparator()
    end
    menu:addOption('Add a filter tab...', function() openSettings(newTab{ name = 'New tab', color = 'green' }, true) end)
    local left = math.ceil((tagUntil - g_clock.millis()) / 1000)
    if left > 0 then
      menu:addOption('[x] Showing sources (' .. left .. ' s left)', function() tagUntil = 0 end)
    else
      menu:addOption('[ ] Show sources for 60 s (debug)', function() tagUntil = g_clock.millis() + 60000 end)
    end
    menu:addOption((truthy(cfg.keepChannels) and '[x] ' or '[ ] ') .. 'Keep my channels open', function()
      cfg.keepChannels = not truthy(cfg.keepChannels)
      save()
      ensureChannels()
    end)
    menu:addOption('Hide the split view', function() cfg.collapsed = true applyLayout() refreshBangs() save() end)
    local b = panel.header.menu
    menu:display({ x = b:getX(), y = b:getY() + b:getHeight() })
  end

  splitter = g_ui.createWidget('BetterChatSplitter', consolePanel)
  splitter:setId('betterChatSplitter')
  anchorLikeContent(splitter)
  splitter:addAnchor(AnchorRight, 'betterChatPanel', AnchorLeft)
  splitter.onMousePress = function(w, pos, button)
    if button ~= MouseLeftButton then return false end
    w.drag = { x = pos.x, w = panel:getWidth() }
    return true
  end
  splitter.onMouseMove = function(w, pos)
    local d = w.drag
    if not d then return false end
    local total = consolePanel:getWidth()
    local nw = math.max(MIN_SPLIT, math.min(d.w + (d.x - pos.x), total - MIN_CONSOLE))
    cfg.width = nw / total
    applyLayout()
    return true
  end
  splitter.onMouseRelease = function(w)
    if w.drag then w.drag = nil save() end
    return false
  end

  connect(g_game, { onTalk = onTalk }, true) -- before the console: its private tab for this very message must not count as open
  connect(g_game, { onTextMessage = onTextMessage, onGameStart = onGameStart, onChannelList = onChannelList })
  connect(consolePanel, { onGeometryChange = applyLayout })
  -- the client only writes the chat/map divider on exit, so a module reload loses whatever height you set.
  -- game_interface.save()/load() are exported: calling them ourselves keeps it without touching the client.
  scheduleEvent(function() pcall(function() modules.game_interface.load() end) end, 400)
  splitEvent = cycleEvent(function()
    if g_game.isOnline() then pcall(function() modules.game_interface.save() end) end
  end, 5000)
  flashEvent = cycleEvent(tick, 500)
  channelsEvent = cycleEvent(ensureChannels, 60000)
  if g_game.isOnline() then scheduleEvent(ensureChannels, 1500) end
  rebuildRail()
  applyLayout()
  scheduleEvent(applyLayout, 500) -- the console may not have its final width yet
  renderActive()
end

function terminate()
  if splitEvent then removeEvent(splitEvent) splitEvent = nil end
  pcall(function() modules.game_interface.save() end)
  disconnect(g_game, { onTalk = onTalk, onTextMessage = onTextMessage, onGameStart = onGameStart, onChannelList = onChannelList })
  if consolePanel then disconnect(consolePanel, { onGeometryChange = applyLayout }) end
  removeEvent(flashEvent)
  removeEvent(channelsEvent)
  if settingsWindow then settingsWindow:destroy() settingsWindow = nil end
  if contentPanel then contentPanel:addAnchor(AnchorRight, 'parent', AnchorRight) end
  for _, w in ipairs({ splitter, panel, rail }) do if w then w:destroy() end end
  splitter, panel, rail = nil, nil, nil
  if cfg then save() end
end
